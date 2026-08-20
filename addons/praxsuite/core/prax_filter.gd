## Where conditions.
##
## Only the operators the gateway's PraxQL parser accepts are exposed:
##   eq, neq, gt, gte, lt, lte, like, ilike, in, is, between, contains, textsearch
##
## `starts_with` and `ends_with` exist as conveniences but compile down to `like` with the
## wildcard already applied, and `is_null`/`is_not_null` compile to `is`/`neq` against null.
## Nothing here sends an operator the server would reject - offering one would only produce a
## runtime 400 on a player's machine.
class_name PraxFilter
extends RefCounted


static func _simple(field: String, op: String, value: Variant, has_value: bool = true) -> Dictionary:
	assert(not field.strip_edges().is_empty(), "A column name is required.")
	var condition := {"field": field.strip_edges(), "op": op}
	if has_value:
		condition["value"] = value
	return condition


static func eq(field: String, value: Variant) -> Dictionary: return _simple(field, "eq", value)
static func neq(field: String, value: Variant) -> Dictionary: return _simple(field, "neq", value)
static func gt(field: String, value: Variant) -> Dictionary: return _simple(field, "gt", value)
static func gte(field: String, value: Variant) -> Dictionary: return _simple(field, "gte", value)
static func lt(field: String, value: Variant) -> Dictionary: return _simple(field, "lt", value)
static func lte(field: String, value: Variant) -> Dictionary: return _simple(field, "lte", value)

## SQL LIKE, case-sensitive. You supply the wildcards.
static func like(field: String, pattern: String) -> Dictionary: return _simple(field, "like", pattern)

## Case-insensitive LIKE.
static func ilike(field: String, pattern: String) -> Dictionary: return _simple(field, "ilike", pattern)

## Substring match, no wildcards needed.
static func contains(field: String, text: String) -> Dictionary: return _simple(field, "contains", text)

## Full-text search over the column.
static func text_search(field: String, q: String) -> Dictionary: return _simple(field, "textsearch", q)

## Prefix match. Compiles to `like 'value%'` - there is no startsWith operator server-side.
static func starts_with(field: String, value: String) -> Dictionary:
	return _simple(field, "like", value + "%")

## Suffix match. Compiles to `like '%value'`.
static func ends_with(field: String, value: String) -> Dictionary:
	return _simple(field, "like", "%" + value)

## field IS NULL. Compiles to `is null` - the gateway's `is` only tests for null.
static func is_null(field: String) -> Dictionary:
	return _simple(field, "is", null)

## field IS NOT NULL. Compiles to `neq null`.
static func is_not_null(field: String) -> Dictionary:
	return _simple(field, "neq", null)


## field IN (...). At least one value is required - an empty IN matches nothing, which is almost
## never what a caller means.
static func in_list(field: String, values: Array) -> Dictionary:
	assert(values.size() > 0,
		"in_list(\"%s\", []) needs at least one value. An empty IN matches nothing - omit the filter instead." % field)
	return _simple(field, "in", values.duplicate())


## field BETWEEN low AND high, inclusive.
static func between(field: String, low: Variant, high: Variant) -> Dictionary:
	return _simple(field, "between", [low, high])


## Matches when any child matches.
static func any_of(filters: Array) -> Dictionary:
	assert(filters.size() > 0, "any_of() needs at least one filter.")
	return {"or": filters.duplicate()}


## Matches when every child matches. Top-level filters are already ANDed, so this is only needed
## to nest an AND group inside an any_of.
static func all_of(filters: Array) -> Dictionary:
	assert(filters.size() > 0, "all_of() needs at least one filter.")
	return {"and": filters.duplicate()}
