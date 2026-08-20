## A chained query. Build it, then await one of the terminal methods.
##
## [codeblock]
## var page = await Prax.data.table("Scores") \
##     .select(["Player", "Score"]) \
##     .where(PraxFilter.gte("Score", 100)) \
##     .order_by_descending("Score") \
##     .limit(20) \
##     .fetch()
## if page is PraxError: return
## for row in page.rows: ...
## [/codeblock]
##
## Nothing is sent until a terminal method (`fetch`, `first`, `count`, `exists`) is awaited, so
## building a query costs nothing.
class_name PraxQuery
extends RefCounted

## The root table's alias inside the request. The gateway addresses tables through `refs`, so the
## alias is an implementation detail callers never see.
const ROOT := "t"

const AGGREGATES := ["count", "sum", "avg", "min", "max"]

## Enforced by the gateway to stop injection through the alias. Rejecting it here means the error
## arrives while you are writing the query, not on a player's machine.
const ALIAS_PATTERN := "^[a-zA-Z_][a-zA-Z0-9_]{0,63}$"

var _data: Object  # PraxData
var _table: String
var _select: Array = []
var _where: Array = []
var _order: Array = []
var _group: Array = []
var _having: Array = []
var _extra_refs: Dictionary = {}
var _limit: int = -1
var _offset: int = -1
var _include_total := false


func _init(data: Object, table: String) -> void:
	assert(not table.strip_edges().is_empty(), "A table name or id is required.")
	_data = data
	_table = table.strip_edges()


## Restricts the columns returned. Worth doing on wide tables - the gateway meters egress
## against the workspace's plan, so fetching columns you discard costs real allowance.
func select(columns: Array) -> PraxQuery:
	for c in columns:
		var name := str(c).strip_edges()
		if not name.is_empty():
			_select.append(name)
	return self


## Includes rows from a related table as a nested array on each row.
func include(related_table: String, columns: Array = [], row_limit: int = -1) -> PraxQuery:
	assert(not related_table.strip_edges().is_empty(), "A related table name or id is required.")
	var alias := "r%d" % (_extra_refs.size() + 1)
	_extra_refs[alias] = related_table.strip_edges()

	var relation := {"table": alias}
	if not columns.is_empty():
		var picked := []
		for c in columns:
			var name := str(c).strip_edges()
			if not name.is_empty():
				picked.append(name)
		if not picked.is_empty():
			relation["select"] = picked
	if row_limit > 0:
		relation["limit"] = row_limit
	_select.append(relation)
	return self


## Adds conditions, built with PraxFilter. Repeated calls are ANDed.
func where(filters: Array) -> PraxQuery:
	for f in filters:
		if f is Dictionary and not f.is_empty():
			_where.append(f)
	return self


## Shorthand for a single equality condition.
func where_eq(column: String, value: Variant) -> PraxQuery:
	_where.append(PraxFilter.eq(column, value))
	return self


func order_by(column: String, ascending: bool = true) -> PraxQuery:
	assert(not column.strip_edges().is_empty(), "A column name is required.")
	_order.append({"field": column.strip_edges(), "dir": "asc" if ascending else "desc"})
	return self


func order_by_descending(column: String) -> PraxQuery:
	return order_by(column, false)


func limit(n: int) -> PraxQuery:
	# The gateway clamps limit up to a minimum of 1, so 0 never means "no rows".
	_limit = maxi(1, n)
	return self


func offset(n: int) -> PraxQuery:
	_offset = maxi(0, n)
	return self


## Asks for the total match count alongside the page. Off by default: it costs the server a
## second counting pass.
func with_total_count() -> PraxQuery:
	_include_total = true
	return self


func group_by(columns: Array) -> PraxQuery:
	for c in columns:
		var name := str(c).strip_edges()
		if not name.is_empty():
			_group.append(name)
	return self


## Conditions applied after grouping. Built with PraxFilter, same as `where`.
func having(filters: Array) -> PraxQuery:
	for f in filters:
		if f is Dictionary and not f.is_empty():
			_having.append(f)
	return self


## Adds an aggregate column, e.g. `aggregate("sum", "Score", "total_score")`.
##
## Aggregations are disabled on a table scope by default, so a 403 here is a scope setting to
## change in the workspace, not a mistake in the query.
func aggregate(fn: String, column: String, alias: String) -> PraxQuery:
	var normalized := fn.strip_edges().to_lower()
	assert(AGGREGATES.has(normalized),
		"Unsupported aggregate \"%s\". The gateway accepts %s." % [fn, ", ".join(AGGREGATES)])

	var re := RegEx.new()
	re.compile(ALIAS_PATTERN)
	assert(re.search(alias) != null,
		"Invalid aggregate alias \"%s\". Use letters, digits and underscore, starting with a letter." % alias)

	_select.append({"field": column.strip_edges() if not column.strip_edges().is_empty() else "*",
		"fn": normalized, "alias": alias.strip_edges()})
	return self


# ─────────────────────────────────────────────────────────────────────────────
# Terminal methods

## Runs the query and returns a PraxResult.Page, or a PraxError.
func fetch() -> Variant:
	var body: Variant = await _data.execute(build())
	if body is PraxError:
		return body
	return PraxResult.parse_page(body)


## The first matching row as a Dictionary, an empty Dictionary when nothing matched, or a
## PraxError. An empty result is not an error - most callers want to branch on it, not handle it.
func first() -> Variant:
	var saved := _limit
	_limit = 1
	var page: Variant = await fetch()
	_limit = saved

	if page is PraxError:
		return page
	return page.rows[0] if not page.rows.is_empty() else {}


func exists() -> Variant:
	var row: Variant = await first()
	if row is PraxError:
		return row
	return not row.is_empty()


## The number of matching rows, ignoring limit and offset.
##
## Implemented as includeTotalCount plus a one-row fetch: the gateway clamps limit up to a
## minimum of 1, so a zero-row request is not possible and asking for one silently returns a row.
func count() -> Variant:
	var saved_limit := _limit
	var saved_offset := _offset
	var saved_total := _include_total

	_limit = 1
	_offset = -1
	_include_total = true

	var page: Variant = await fetch()

	_limit = saved_limit
	_offset = saved_offset
	_include_total = saved_total

	if page is PraxError:
		return page
	if page.total < 0:
		return PraxError.new("TOTAL_COUNT_UNAVAILABLE",
			"The gateway returned no total count. Aggregations are probably disabled on this table's scope - enable them in the workspace's API Gateway settings.")
	return page.total


## The request body this query will send. Public because seeing it is the fastest way to
## understand a 400, and because the tests assert on it.
func build() -> Dictionary:
	var refs := {ROOT: _data.resolve_table(_table)}
	for alias in _extra_refs:
		refs[alias] = _data.resolve_table(_extra_refs[alias])

	var query := {"from": ROOT}
	if not _select.is_empty(): query["select"] = _select
	if not _where.is_empty(): query["where"] = _where
	if not _order.is_empty(): query["orderBy"] = _order
	if not _group.is_empty(): query["groupBy"] = _group
	if not _having.is_empty(): query["having"] = _having
	if _limit >= 0: query["limit"] = _limit
	if _offset >= 0: query["offset"] = _offset

	var request := {"refs": refs, "query": query}
	# includeTotalCount sits beside query, not inside it.
	if _include_total:
		request["includeTotalCount"] = true
	return request
