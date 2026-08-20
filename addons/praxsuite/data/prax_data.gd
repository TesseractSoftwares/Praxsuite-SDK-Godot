## Reads and writes table rows. Reached through the client: `Prax.data`.
##
## Every call is authorised twice on the server: the credential (or the signed-in player's role)
## must be scoped to the table, and any row filter on that scope is applied on top of your
## conditions. A client cannot widen either, which is why this SDK exposes no way to try.
class_name PraxData
extends RefCounted

const ROOT := PraxQuery.ROOT

## Columns the backend fills in and rejects if a client supplies them.
const NATIVE_COLUMNS := ["ID", "CREATEDDATE", "CREATEDBY", "UPDATEDDATE", "UPDATEDBY", "POSITION"]

var _client: Object  # PraxsuiteClient


func _init(client: Object) -> void:
	_client = client


## Starts a query against a table, by name or id.
func table(name_or_id: String) -> PraxQuery:
	return PraxQuery.new(self, name_or_id)


# ─────────────────────────────────────────────────────────────────────────────
# Writes
#
# Every guardrail below returns its PraxError before awaiting anything, so a refusal costs no
# round trip.
#
# GDScript is unusually good to us here. Calling a coroutine without `await` is a PARSE error,
# so a script that ignores one of these results does not compile at all. In C# and JavaScript the
# same mistake produces a faulted task or a rejected promise that a caller can drop on the
# floor - no write, no error, complete silence. For a check whose job is preventing an accidental
# table-wide write, silence is the worst possible outcome, and here the engine makes it
# impossible.

## Inserts one row. Returns a PraxResult.MutationResult carrying the created row.
##
## Do not set an ownership column yourself. A column carrying a DefaultValueTemplate is stamped
## from the caller's verified token and the gateway rejects a request that supplies it - that
## rejection is the anti-tamper guarantee, so working around it defeats the isolation.
func insert(table_name: String, values: Dictionary) -> Variant:
	if values.is_empty():
		return PraxError.new("INVALID_REQUEST", "insert() needs at least one column to set.")
	var offending := _find_native_columns(values.keys())
	if not offending.is_empty():
		return PraxError.new("INVALID_REQUEST",
			"The backend fills %s in - remove them from the insert." % ", ".join(offending))
	return await _mutate(table_name, {"type": "insert", "table": ROOT, "values": [values], "returning": true})


## Inserts several rows in one request.
func insert_many(table_name: String, rows: Array) -> Variant:
	var values := []
	for r in rows:
		if r is Dictionary and not r.is_empty():
			values.append(r)
	if values.is_empty():
		return PraxError.new("INVALID_REQUEST", "insert_many() needs at least one non-empty row.")
	for r in values:
		var offending := _find_native_columns(r.keys())
		if not offending.is_empty():
			return PraxError.new("INVALID_REQUEST",
				"The backend fills %s in - remove them from the insert." % ", ".join(offending))
	return await _mutate(table_name, {"type": "insert", "table": ROOT, "values": values, "returning": true})


## Updates every row matching `filters`.
##
## The conditions are mandatory. The gateway rejects an unscoped update, and refusing here means
## the mistake surfaces while you are writing the code rather than as a 400 in production.
func update(table_name: String, values: Dictionary, filters: Array) -> Variant:
	if values.is_empty():
		return PraxError.new("INVALID_REQUEST", "update() needs at least one column to set.")
	if filters.is_empty():
		return PraxError.new("UNSCOPED_MUTATION",
			"update() requires conditions. An update with no WHERE would target every row you can reach; pass filters, or use update_by_id().")
	var offending := _find_native_columns(values.keys())
	if not offending.is_empty():
		return PraxError.new("INVALID_REQUEST",
			"The backend maintains %s - remove them from the update." % ", ".join(offending))
	return await _mutate(table_name,
		{"type": "update", "table": ROOT, "set": values, "where": filters})


func update_by_id(table_name: String, row_id: String, values: Dictionary) -> Variant:
	if row_id.strip_edges().is_empty():
		return PraxError.new("INVALID_REQUEST", "update_by_id() needs a row id.")
	return await update(table_name, values, [PraxFilter.eq("ID", row_id.strip_edges())])


## Deletes every row matching `filters`. Conditions are mandatory, for the same reason as update.
func delete(table_name: String, filters: Array) -> Variant:
	if filters.is_empty():
		return PraxError.new("UNSCOPED_MUTATION",
			"delete() requires conditions. A delete with no WHERE would remove every row you can reach; pass filters, or use delete_by_id().")
	return await _mutate(table_name, {"type": "delete", "table": ROOT, "where": filters})


func delete_by_id(table_name: String, row_id: String) -> Variant:
	if row_id.strip_edges().is_empty():
		return PraxError.new("INVALID_REQUEST", "delete_by_id() needs a row id.")
	return await delete(table_name, [PraxFilter.eq("ID", row_id.strip_edges())])


## Updates the row when `row_id` is a non-empty string, inserts otherwise. Convenient for a save
## slot that may or may not exist yet.
func upsert(table_name: String, values: Dictionary, row_id: String = "") -> Variant:
	if not row_id.strip_edges().is_empty():
		return await update_by_id(table_name, row_id, values)
	return await insert(table_name, values)


# ─────────────────────────────────────────────────────────────────────────────

## Sends a hand-built PraxQL request. The escape hatch for shapes the builder does not cover.
func execute(request: Dictionary) -> Variant:
	if request.is_empty():
		return PraxError.new("INVALID_REQUEST", "A request body is required.")
	var url := PraxRoutes.query(_client.base_url, _client.workspace_id)
	# Reads are safe to retry; a mutation is not, so retries are decided per request.
	var retry_safe := not request.has("mutation")
	return await _client.send(HTTPClient.METHOD_POST, url, request, retry_safe)


## Resolves a table name to whatever the gateway addresses it by. Kept as a seam so a future
## name-to-id lookup does not change every call site.
func resolve_table(name_or_id: String) -> String:
	return name_or_id.strip_edges()


func _mutate(table_name: String, mutation: Dictionary) -> Variant:
	var body: Variant = await execute({
		"refs": {ROOT: resolve_table(table_name)},
		"mutation": mutation,
	})
	if body is PraxError:
		return body
	return PraxResult.parse_mutation(body)


static func _find_native_columns(keys: Array) -> Array:
	var found := []
	for k in keys:
		if NATIVE_COLUMNS.has(str(k).to_upper()):
			found.append(str(k))
	return found
