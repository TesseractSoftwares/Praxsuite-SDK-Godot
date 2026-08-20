## Parsers for the shapes the gateway returns.
##
## The gateway is not uniform, and an SDK that assumes one envelope will mis-read two:
##   /query    -> the body IS the result: {data, meta}
##   /auth/*   -> the platform envelope:  {isSuccess, message, errors, data}
##   /files    -> a bare string error:    {error: "..."}
class_name PraxResult
extends RefCounted


## A page of rows plus the query's metadata.
class Page extends RefCounted:
	var rows: Array = []
	## Rows in this page.
	var count: int = 0
	## The limit actually applied - the server caps it per table scope, so this may be lower
	## than what was requested.
	var limit: int = 0
	var offset: int = 0
	## Total matching rows ignoring limit/offset. -1 when not requested, so "no rows" stays
	## distinguishable from "not counted".
	var total: int = -1
	var duration_ms: int = 0

	var has_more: bool:
		get:
			if total >= 0:
				return offset + count < total
			return count >= limit and limit > 0


## Result of an insert, update or delete.
class MutationResult extends RefCounted:
	var affected_rows: int = 0
	## Rows returned by an insert with returning enabled. Empty otherwise.
	var rows: Array = []
	var duration_ms: int = 0

	var row: Variant:
		get: return rows[0] if rows.size() > 0 else null


static func _as_int(value: Variant, fallback: int = 0) -> int:
	if value is int:
		return value
	if value is float:
		return roundi(value)
	if value is String and value.is_valid_int():
		return value.to_int()
	return fallback


## Reads the data array and meta block of a query response.
##
## The total-count field is named "total". Reading a different name returns nothing and reports
## zero forever - a mistake that shipped in another Praxsuite SDK and went unnoticed for months,
## which is why a test pins it.
static func parse_page(body: Dictionary) -> Page:
	var page := Page.new()
	if body.has("data") and body["data"] is Array:
		page.rows = body["data"]

	var meta: Dictionary = body.get("meta", {}) if body.get("meta") is Dictionary else {}
	page.count = _as_int(meta.get("count"), page.rows.size())
	page.limit = _as_int(meta.get("limit"))
	page.offset = _as_int(meta.get("offset"))
	page.duration_ms = _as_int(meta.get("durationMs"))
	page.total = _as_int(meta.get("total"), -1) if meta.has("total") and meta.get("total") != null else -1
	return page


static func parse_mutation(body: Dictionary) -> MutationResult:
	var result := MutationResult.new()
	result.affected_rows = _as_int(body.get("affectedRows"))
	if body.has("data") and body["data"] is Array:
		result.rows = body["data"]
	var meta: Dictionary = body.get("meta", {}) if body.get("meta") is Dictionary else {}
	result.duration_ms = _as_int(meta.get("durationMs"))
	return result


## Unwraps the platform envelope used by /auth/* - the payload sits under .data.
##
## Deliberately NOT applied to /query, whose .data is the row array itself. An SDK that unwraps
## both, or neither, breaks one of them.
static func unwrap_envelope(body: Dictionary) -> Dictionary:
	if body.has("data") and body["data"] is Dictionary:
		return body["data"]
	return body


## Builds a typed error from a non-2xx body, handling all three shapes above.
static func parse_error(status: int, raw_body: String) -> PraxError:
	var code := ""
	var message := ""
	var details := PackedStringArray()

	if not raw_body.is_empty():
		var parsed: Variant = parse_json_quietly(raw_body)
		if parsed is Dictionary:
			var err: Variant = parsed.get("error")
			if err is Dictionary:
				code = str(err.get("code", ""))
				message = str(err.get("message", ""))
				if err.get("details") is Array:
					for d in err["details"]:
						details.append(str(d))
			elif err is String:
				message = err
			else:
				message = str(parsed.get("message", ""))
				if parsed.get("errors") is Array:
					for d in parsed["errors"]:
						details.append(str(d))
		else:
			# Not JSON - an HTML error page from an edge proxy, most likely.
			message = raw_body.substr(0, 400)

	if code.is_empty():
		code = "HTTP_%d" % status
	if message.is_empty():
		message = _describe_status(status)

	return PraxError.new(code, message, status, details, raw_body)


static func _describe_status(status: int) -> String:
	match status:
		400: return "The gateway rejected the request as malformed."
		401: return "Not authenticated. The API key or session token is missing, expired, or does not belong to this workspace."
		403: return "Authenticated, but not permitted. Check the credential's or role's table scopes in API Gateway settings."
		404: return "Not found. Verify the workspace id, and that you are pointed at the tier that hosts it - a workspace on another tier returns 404 here."
		413: return "The payload is larger than the workspace plan allows."
		429: return "Rate limited or out of plan allowance."
		500: return "The gateway hit an internal error."
		502, 503, 504: return "The gateway is unavailable or timed out upstream."
	return "The gateway returned HTTP %d." % status


## Parses JSON without Godot's engine-level error on failure. Returns null when the text is not
## JSON.
##
## JSON.parse_string() pushes an error into the console even when the caller handles the failure,
## which would make every HTML error page from an edge proxy look like an SDK crash.
static func parse_json_quietly(text: String) -> Variant:
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return null
	return parser.data
