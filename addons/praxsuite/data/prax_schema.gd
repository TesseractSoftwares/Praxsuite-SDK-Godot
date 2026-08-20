## Reads the tables and columns this credential is allowed to see.
##
## Useful for a debug panel or a build-time check. It is not something a shipped game needs on
## every launch: the schema only changes when you change it, and the result is cached here for
## the process lifetime.
##
## What comes back is filtered by scope. A table you have not granted access to simply is not
## listed, and a column hidden from the credential is absent rather than empty - so this is also
## the quickest way to confirm a scope is configured the way you think it is.
class_name PraxSchema
extends RefCounted

var _client: Object  # PraxsuiteClient
var _cache: Dictionary = {}
var _loaded := false


func _init(client: Object) -> void:
	_client = client


## Every visible table, keyed by name. Cached after the first call.
func tables(force_reload: bool = false) -> Variant:
	if _loaded and not force_reload:
		return _cache

	var url := PraxRoutes.schema(_client.base_url, _client.workspace_id)
	var response: Variant = await _client.send(HTTPClient.METHOD_GET, url, null, true)
	if response is PraxError:
		return response

	var body := PraxResult.unwrap_envelope(response)
	var listed: Variant = body.get("tables", [])
	if not (listed is Array):
		return PraxError.new("MALFORMED_RESPONSE", "The schema response had no tables array.")

	_cache.clear()
	for entry in listed:
		if entry is Dictionary:
			_cache[str(entry.get("name", ""))] = entry
	_loaded = true
	return _cache


## One table's definition, or an empty Dictionary when it is not visible to this credential.
func table(name: String) -> Variant:
	var all: Variant = await tables()
	if all is PraxError:
		return all
	return all.get(name, {})


## The column names visible on a table.
func columns(table_name: String) -> Variant:
	var definition: Variant = await table(table_name)
	if definition is PraxError:
		return definition

	var names := PackedStringArray()
	var listed: Variant = definition.get("columns", [])
	if listed is Array:
		for c in listed:
			if c is Dictionary:
				names.append(str(c.get("name", "")))
	return names


## True when the table is visible to this credential. The fastest way to tell a typo apart from
## a missing scope: a typo and an unscoped table look identical in a 403.
func has_table(name: String) -> Variant:
	var definition: Variant = await table(name)
	if definition is PraxError:
		return definition
	return not definition.is_empty()
