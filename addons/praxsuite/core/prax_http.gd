## The one place this SDK talks to the network.
##
## Godot's HTTPRequest is a Node, so every call briefly parents one to a host node, awaits
## `request_completed`, and frees it. That is why PraxsuiteClient is a Node - it is the host.
##
## Returns either a parsed Dictionary or a PraxError. Nothing here throws, because GDScript has
## no exceptions.
class_name PraxHttp
extends RefCounted

## Retries are only ever attempted for transient failures, and only for idempotent reads.
## Retrying a failed insert is how you get two rows.
const MAX_ATTEMPTS := 3
const BASE_BACKOFF_SECONDS := 0.4

var _host: Node
var _timeout_seconds: float


func _init(host: Node, timeout_seconds: float = 20.0) -> void:
	_host = host
	_timeout_seconds = timeout_seconds


## Sends one request and returns the decoded JSON body, or a PraxError.
##
## `retry_safe` must only be true for operations that can be repeated without changing state.
func request_json(method: int, url: String, headers: Dictionary, body: Variant = null,
		retry_safe: bool = false) -> Variant:
	var attempts := MAX_ATTEMPTS if retry_safe else 1
	var last_error: PraxError = null

	for attempt in range(attempts):
		if attempt > 0:
			# Exponential, so a rate-limited client backs off instead of hammering.
			var delay := BASE_BACKOFF_SECONDS * pow(2.0, attempt - 1)
			PraxLog.verbose("Retrying in %.1fs (attempt %d of %d)" % [delay, attempt + 1, attempts])
			await _host.get_tree().create_timer(delay).timeout

		var outcome: Variant = await _send_once(method, url, headers, body)
		if not (outcome is PraxError):
			return outcome

		last_error = outcome
		if not last_error.is_transient:
			return last_error

	return last_error


func _send_once(method: int, url: String, headers: Dictionary, body: Variant) -> Variant:
	if _host == null or not is_instance_valid(_host):
		return PraxError.new("CLIENT_DISPOSED",
			"The Praxsuite client node was freed before this request finished.")

	var http := HTTPRequest.new()
	http.timeout = _timeout_seconds
	# The gateway always answers JSON, and decompressing it ourselves buys nothing.
	http.accept_gzip = true
	_host.add_child(http)

	var header_lines := PackedStringArray()
	for key in headers:
		header_lines.append("%s: %s" % [key, headers[key]])

	var payload := "" if body == null else JSON.stringify(body)
	if not payload.is_empty():
		header_lines.append("Content-Type: application/json")

	PraxLog.verbose("-> %s %s" % [_method_name(method), url])

	var err := http.request(url, header_lines, method, payload)
	if err != OK:
		http.queue_free()
		return PraxError.new("NETWORK_ERROR",
			"Could not start the request (Godot error %d). Check the base URL." % err)

	var result: Array = await http.request_completed
	http.queue_free()

	var transport: int = result[0]
	var status: int = result[1]
	var raw: PackedByteArray = result[3]
	var text := raw.get_string_from_utf8()

	if transport != HTTPRequest.RESULT_SUCCESS:
		return _transport_error(transport)

	PraxLog.verbose("<- %d %s (%d bytes)" % [status, url, raw.size()])

	if status < 200 or status > 299:
		return PraxResult.parse_error(status, text)

	# 204 and an empty 200 are both legitimate: a logout returns no body.
	if text.strip_edges().is_empty():
		return {}

	var parsed: Variant = PraxResult.parse_json_quietly(text)
	if parsed == null:
		return PraxError.new("MALFORMED_RESPONSE",
			"The gateway returned HTTP %d with a body that is not JSON." % status, status,
			PackedStringArray(), text)
	if not (parsed is Dictionary):
		return PraxError.new("MALFORMED_RESPONSE",
			"Expected a JSON object from the gateway but got %s." % type_string(typeof(parsed)),
			status, PackedStringArray(), text)

	return parsed


## Transport failures never reached the gateway, so there is no status and no body. They are
## reported as NETWORK_ERROR/TIMEOUT so callers can treat "offline" separately from "rejected".
static func _transport_error(transport: int) -> PraxError:
	match transport:
		HTTPRequest.RESULT_TIMEOUT:
			return PraxError.new("TIMEOUT", "The request timed out before the gateway answered.")
		HTTPRequest.RESULT_CANT_CONNECT:
			return PraxError.new("NETWORK_ERROR", "Could not connect to the gateway.")
		HTTPRequest.RESULT_CANT_RESOLVE:
			return PraxError.new("NETWORK_ERROR", "Could not resolve the gateway host name.")
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return PraxError.new("NETWORK_ERROR", "The connection to the gateway dropped.")
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return PraxError.new("NETWORK_ERROR",
				"The TLS handshake with the gateway failed. On an export template without CA certificates, set a custom bundle in Project Settings.")
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return PraxError.new("RESPONSE_TOO_LARGE",
				"The response exceeded the body size limit. Lower your page size.")
		_:
			return PraxError.new("NETWORK_ERROR", "The request failed before reaching the gateway (result %d)." % transport)


static func _method_name(method: int) -> String:
	match method:
		HTTPClient.METHOD_GET: return "GET"
		HTTPClient.METHOD_POST: return "POST"
		HTTPClient.METHOD_PATCH: return "PATCH"
		HTTPClient.METHOD_PUT: return "PUT"
		HTTPClient.METHOD_DELETE: return "DELETE"
		_: return "?"
