## Offline conformance tests, runnable headless:
##
##   godot --headless --path . --script addons/praxsuite/tests/run_tests.gd
##
## No network, no workspace, no credentials. Every case mirrors the shared Praxsuite SDK
## conformance contract, so behaviour cannot drift between languages. Each one exists because
## getting it wrong produces silently wrong data rather than an error.
##
## Deliberately hand-rolled rather than GUT: the SDK has no dependencies, and neither should
## its test runner.
extends SceneTree

var _passed := 0
var _failed := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  PASS  " + name)
	else:
		_failed += 1
		print("  FAIL  " + name + ("" if detail.is_empty() else "  <- " + detail))


func _eq(name: String, actual: Variant, expected: Variant) -> void:
	_check(name, str(actual) == str(expected), "got %s, expected %s" % [actual, expected])


func _init() -> void:
	print("\nPraxsuite SDK for Godot - conformance tests\n")

	_test_filters()
	_test_parsing()
	_test_errors()
	_test_credentials()
	_test_routes()
	_test_encoding()
	_test_query_building()
	await _test_write_guardrails()
	_test_secret_scan()
	_test_endpoints()
	_test_event_bus()

	print("\n%d passed, %d failed\n" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _test_filters() -> void:
	print("filters build the gateway wire shape")

	_eq("eq", PraxFilter.eq("Score", 100), {"field": "Score", "op": "eq", "value": 100})

	# There is no isNull operator server-side; "is" only tests for null.
	_eq("is_null compiles to the is operator",
		PraxFilter.is_null("DeletedAt"), {"field": "DeletedAt", "op": "is", "value": null})
	_eq("is_not_null compiles to neq null",
		PraxFilter.is_not_null("DeletedAt"), {"field": "DeletedAt", "op": "neq", "value": null})

	_eq("starts_with compiles to like with a wildcard",
		PraxFilter.starts_with("Name", "Sword"), {"field": "Name", "op": "like", "value": "Sword%"})
	_eq("ends_with compiles to like with a wildcard",
		PraxFilter.ends_with("Name", "blade"), {"field": "Name", "op": "like", "value": "%blade"})

	_eq("in carries an array",
		PraxFilter.in_list("Level", [1, 2, 3]), {"field": "Level", "op": "in", "value": [1, 2, 3]})
	_eq("between carries exactly two values",
		PraxFilter.between("Score", 10, 20), {"field": "Score", "op": "between", "value": [10, 20]})

	var or_group := PraxFilter.any_of([PraxFilter.eq("Rarity", "legendary"), PraxFilter.eq("Rarity", "epic")])
	_check("or groups nest under an or key", or_group.has("or") and or_group["or"].size() == 2)

	var and_group := PraxFilter.all_of([PraxFilter.gte("Level", 5), PraxFilter.lte("Level", 10)])
	_check("and groups nest under an and key", and_group.has("and") and and_group["and"].size() == 2)


func _test_parsing() -> void:
	print("\nresult parsing")

	# Reading meta.totalCount instead of meta.total returns nothing and reports 0 forever.
	# That exact mistake shipped in another SDK and went unnoticed for months.
	var page := PraxResult.parse_page({
		"data": [{"ID": "a"}, {"ID": "b"}],
		"meta": {"limit": 50, "offset": 0, "count": 2, "total": 137, "durationMs": 12},
	})
	_eq("page reads total, not totalCount", page.total, 137)
	_eq("page row count", page.rows.size(), 2)
	_eq("page limit", page.limit, 50)
	_eq("page duration", page.duration_ms, 12)
	_check("has_more when more rows remain", page.has_more)

	# An absent total must stay distinguishable from a zero count.
	var no_total := PraxResult.parse_page({"data": [], "meta": {"limit": 50, "count": 0}})
	_eq("absent total is -1, not 0", no_total.total, -1)

	var mutation := PraxResult.parse_mutation({
		"affectedRows": 1, "data": [{"ID": "new-row"}], "meta": {"durationMs": 8},
	})
	_eq("mutation affected rows", mutation.affected_rows, 1)
	_eq("mutation returned row", mutation.row, {"ID": "new-row"})

	# /auth nests the payload under .data; /query does not.
	_eq("auth envelope is unwrapped",
		PraxResult.unwrap_envelope({"isSuccess": true, "data": {"accessToken": "a.b.c"}}),
		{"accessToken": "a.b.c"})
	var query_body := {"data": [{"ID": "x"}], "meta": {"count": 1}}
	_check("a query body is NOT unwrapped",
		PraxResult.unwrap_envelope(query_body).has("meta"),
		"an array .data must be left alone")


func _test_errors() -> void:
	print("\nerror shapes and classification")

	var forbidden := PraxResult.parse_error(403,
		'{"error":{"code":"FORBIDDEN","message":"Read access denied.","details":["scope"]}}')
	_eq("query error code", forbidden.code, "FORBIDDEN")
	_check("is_forbidden", forbidden.is_forbidden)
	_check("403 is not transient", not forbidden.is_transient)
	_eq("details parsed", forbidden.details.size(), 1)

	var files_error := PraxResult.parse_error(400, '{"error":"File type not allowed."}')
	_eq("files error is a bare string", files_error.message, "File type not allowed.")

	# An edge proxy answering with an HTML 502 is routine. Parsing it must neither crash nor
	# push an engine-level error into the console, which JSON.parse_string does even when the
	# caller handles the failure.
	var html := PraxResult.parse_error(502, "<html>Bad Gateway</html>")
	_check("a non-JSON body does not crash the parser", html.message.contains("Bad Gateway"))
	_check("a non-JSON body parses quietly", PraxResult.parse_json_quietly("<html>x</html>") == null)
	var reparsed: Variant = PraxResult.parse_json_quietly('{"a":1}')
	_check("valid JSON still parses", reparsed is Dictionary and reparsed["a"] == 1)

	# Godot's JSON decodes every number as a float, so an Int column arrives as 1.0 rather than 1.
	# Anything used as an index, a count or an id needs an explicit int() - this is asserted so
	# the behaviour is documented rather than discovered.
	_check("whole numbers arrive as floats", typeof(reparsed["a"]) == TYPE_FLOAT)
	_eq("int() recovers a usable integer", int(reparsed["a"]), 1)

	# Quota and rate limit share HTTP 429 and classify oppositely.
	_check("rate limit is transient", PraxError.new("RATE_LIMIT_EXCEEDED", "", 429).is_transient)
	_check("quota is NOT transient", not PraxError.new("QUOTA_EXCEEDED", "", 429).is_transient)
	_check("quota is flagged as quota", PraxError.new("QUOTA_EXCEEDED", "", 429).is_quota_exceeded)
	_check("egress limit is flagged as quota", PraxError.new("EGRESS_LIMIT_EXCEEDED", "", 429).is_quota_exceeded)
	_check("network error is transient", PraxError.new("NETWORK_ERROR", "").is_transient)
	_check("503 is transient", PraxError.new("HTTP_503", "", 503).is_transient)


func _test_credentials() -> void:
	print("\ncredential handling")

	# Shape-accurate fakes, assembled from fragments so a secret scanner does not flag this file.
	var fake_secret := "sk_live_" + "0123456789abcdef0123456789abcdef"
	var fake_publishable := "pk_live_" + "fedcba9876543210fedcba9876543210"
	var fake_jwt := "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhYmMifQ.signaturehere"

	_check("secret classified", PraxKeyGuard.classify(fake_secret) == PraxKeyGuard.Kind.SECRET)
	_check("publishable classified", PraxKeyGuard.classify(fake_publishable) == PraxKeyGuard.Kind.PUBLISHABLE)
	_check("jwt classified", PraxKeyGuard.classify(fake_jwt) == PraxKeyGuard.Kind.JWT)
	_check("empty is unknown", PraxKeyGuard.classify("") == PraxKeyGuard.Kind.UNKNOWN)

	_check("game code refuses a secret key",
		PraxKeyGuard.check_client_safe(fake_secret, "a test") != null)
	_check("publishable key accepted",
		PraxKeyGuard.check_client_safe(fake_publishable, "a test") == null)
	_check("session token accepted",
		PraxKeyGuard.check_client_safe(fake_jwt, "a test") == null)

	var masked := PraxKeyGuard.redact(fake_secret)
	_check("redaction keeps the prefix", masked.begins_with("sk_live_"))
	_check("redaction hides key material", not masked.contains("0123456789abcdef"), masked)

	var scrubbed := PraxLog.scrub(
		"key=%s jwt=%s {\"refreshToken\":\"rt-secret-value\",\"password\":\"hunter2\"}"
		% [fake_secret, fake_jwt])
	_check("scrub removes the secret key", not scrubbed.contains("0123456789abcdef"))
	_check("scrub removes the jwt", not scrubbed.contains("signaturehere"))
	_check("scrub removes the refresh token", not scrubbed.contains("rt-secret-value"), scrubbed)
	_check("scrub removes the password", not scrubbed.contains("hunter2"), scrubbed)


func _test_routes() -> void:
	print("\nroutes")

	var ws := "1eb92f32-d628-4656-8c64-cd0d43c9869d"
	_eq("query uses the FrontDoor short form",
		PraxRoutes.query("https://gateway.praxsuite.com", ws),
		"https://gateway.praxsuite.com/%s/query" % ws)
	_eq("auth actions nest under auth/",
		PraxRoutes.auth("https://gateway.praxsuite.com", ws, "login"),
		"https://gateway.praxsuite.com/%s/auth/login" % ws)
	_eq("trailing slash and missing scheme normalised",
		PraxRoutes.schema("gateway.praxsuite.com/", ws),
		"https://gateway.praxsuite.com/%s/schema" % ws)

	_check("plaintext remote flagged", PraxRoutes.is_insecure_remote("http://gateway.example.com"))
	_check("https not flagged", not PraxRoutes.is_insecure_remote("https://gateway.example.com"))
	_check("loopback allowed", not PraxRoutes.is_insecure_remote("http://localhost:5049"))
	_check("127.0.0.1 allowed", not PraxRoutes.is_insecure_remote("http://127.0.0.1:5049"))


func _test_encoding() -> void:
	print("\nencoding")

	# Display names contain emoji constantly; a codec that mangles them corrupts data silently.
	var name := "Aria 🚀🇨🇱"
	var round_tripped: Variant = JSON.parse_string(JSON.stringify({"name": name}))
	_eq("astral emoji survive a round trip", round_tripped["name"], name)

	var escaped: Variant = JSON.parse_string('{"name":"\\ud83d\\ude80"}')
	_eq("escaped surrogate pairs decode to one character", escaped["name"], "🚀")

	_eq("a dictionary serialises as a JSON object", JSON.stringify({"Score": 10}), '{"Score":10}')


func _test_query_building() -> void:
	print("
query building")

	# PraxData needs a client only to send. Building a request touches nothing, which is what
	# makes this testable with no workspace and no network.
	var data := PraxData.new(null)

	var simple: Dictionary = data.table("Scores").build()
	_eq("root table lands in refs", simple["refs"], {"t": "Scores"})
	_eq("query selects from the root alias", simple["query"]["from"], "t")
	_check("no limit is sent unless asked for", not simple["query"].has("limit"))
	_check("includeTotalCount is absent by default", not simple.has("includeTotalCount"))

	var full: Dictionary = data.table("Scores") 		.select(["Player", "Score"]) 		.where([PraxFilter.gte("Score", 100)]) 		.where_eq("Season", 3) 		.order_by_descending("Score") 		.limit(20) 		.offset(40) 		.with_total_count() 		.build()

	_eq("select carries the named columns", full["query"]["select"], ["Player", "Score"])
	_eq("repeated where calls are ANDed into one list", full["query"]["where"].size(), 2)
	_eq("order uses dir, not direction",
		full["query"]["orderBy"], [{"field": "Score", "dir": "desc"}])
	_eq("limit", full["query"]["limit"], 20)
	_eq("offset", full["query"]["offset"], 40)
	# includeTotalCount sits beside query, not inside it. Nesting it is silently ignored, and the
	# total then comes back absent forever.
	_check("includeTotalCount sits at the top level",
		full.get("includeTotalCount") == true and not full["query"].has("includeTotalCount"))

	# limit(0) would mean "no rows", but the gateway clamps limit up to 1 - so a zero-row request
	# is impossible and asking for one silently returns a row.
	var clamped: Dictionary = data.table("Scores").limit(0).build()
	_eq("limit is clamped up to 1, never 0", clamped["query"]["limit"], 1)

	var joined: Dictionary = data.table("Players").include("Inventory", ["Item"], 10).build()
	_eq("an included table gets its own ref", joined["refs"].size(), 2)
	_check("the relation points at the alias, not the table name",
		joined["query"]["select"][0]["table"] == "r1")

	var aggregated: Dictionary = data.table("Scores").aggregate("sum", "Score", "total").build()
	_eq("aggregate shape", aggregated["query"]["select"][0],
		{"field": "Score", "fn": "sum", "alias": "total"})


func _test_write_guardrails() -> void:
	print("
write guardrails")

	var data := PraxData.new(null)

	# Every guardrail refuses before the first await, so these resolve without a client and
	# without touching the network. GDScript refuses at PARSE time to call a coroutine without
	# await, so the "caller forgot to await and got silence" failure other languages have simply
	# cannot happen here - which is why these are awaited rather than called bare.
	var unscoped_update: Variant = await data.update("Scores", {"Score": 0}, [])
	_check("update with no conditions is refused",
		unscoped_update is PraxError and unscoped_update.code == "UNSCOPED_MUTATION")

	var unscoped_delete: Variant = await data.delete("Scores", [])
	_check("delete with no conditions is refused",
		unscoped_delete is PraxError and unscoped_delete.code == "UNSCOPED_MUTATION")

	_check("empty insert is refused", await data.insert("Scores", {}) is PraxError)
	_check("empty update values are refused",
		await data.update("Scores", {}, [PraxFilter.eq("ID", "x")]) is PraxError)
	_check("update_by_id with a blank id is refused",
		await data.update_by_id("Scores", "  ", {"Score": 1}) is PraxError)

	# The backend fills these in and rejects a request that supplies them.
	var native: Variant = await data.insert("Scores", {"ID": "forced", "Score": 1})
	_check("supplying a native column is refused", native is PraxError)
	_check("the message names the offending column",
		native is PraxError and native.message.contains("ID"))

	var native_update: Variant = await data.update("Scores", {"CreatedDate": "now"},
		[PraxFilter.eq("ID", "x")])
	_check("native columns are caught case-insensitively", native_update is PraxError)


func _test_secret_scan() -> void:
	print("
secret scan")

	# The SDK's own source must be clean, and the scanner must not flag its own test fixtures -
	# which is why those fakes are assembled from fragments at runtime.
	var offenders := PraxSecretScan.scan_directory("res://addons/praxsuite/")
	_check("the SDK source carries no secret key", offenders.is_empty(), str(offenders))


func _test_endpoints() -> void:
	print("
endpoints (measured against a live gateway)")

	var endpoints := PraxEndpoints.new(null)

	# GET never reaches the automation - the gateway consumes it as a Meta webhook verification
	# handshake and answers 400. Offering a GET helper would be offering a call that cannot work.
	_check("no GET helper is exposed", not endpoints.has_method("get_endpoint"))

	# A Sync endpoint holds the connection while its automation runs. syncTimeoutSeconds values of
	# 30, 45, 60 and 90 were all observed in one workspace; the client default is 20s.
	_check("endpoint timeout clears the observed maximum",
		PraxEndpoints.DEFAULT_ENDPOINT_TIMEOUT >= 90.0)

	# A blank id must be refused before any request is built.
	var refused: Variant = await endpoints.call_endpoint("  ")
	_check("a blank endpoint id is refused",
		refused is PraxError and refused.code == "INVALID_REQUEST")


func _test_event_bus() -> void:
	print("\nevent bus (measured against a live hub, 2026-09-07)")

	# The server folds only the TOPIC segment. Folding the whole key would merge office:HQ and
	# office:hq, which are two different buses; folding neither lets two clients resolve the same
	# topic, both be admitted, and silently never see each other.
	_eq("the topic folds and the instance does not",
		PraxBusWire.normalize_bus_key("Office:HQ"), "office:HQ")
	_eq("a key with no instance still folds", PraxBusWire.normalize_bus_key("LOBBY"), "lobby")
	_eq("whitespace is trimmed", PraxBusWire.normalize_bus_key("  office:hq  "), "office:hq")
	_eq("user:self passes through", PraxBusWire.normalize_bus_key("user:self"), "user:self")

	_check("an empty key is refused before the round trip",
		PraxBusWire.check_bus_key("   ") != null)
	_check("a key containing ws: is refused",
		PraxBusWire.check_bus_key("x:ws:something") != null)
	_check("a valid key passes", PraxBusWire.check_bus_key("office:hq") == null)

	# SignalR compares the handshake literally: a space after a colon fails it.
	_eq("the handshake is byte-exact",
		PraxBusWire.HANDSHAKE_FRAME, '{"protocol":"json","version":1}')

	# One physical message can carry several frames, and a transport may split one across two
	# reads. Parsing the whole buffer breaks under exactly the load the bus exists for.
	var rs := "\u001e"
	var one := PraxBusWire.split_frames('{"type":6}' + rs)
	_check("a single frame splits to one message",
		one["frames"].size() == 1 and one["remainder"] == "")

	var two := PraxBusWire.split_frames(
		'{"type":6}' + rs + '{"type":3,"invocationId":"1","result":null}' + rs)
	_check("two coalesced frames split into two", two["frames"].size() == 2)

	var partial := PraxBusWire.split_frames('{"type":6}' + rs + '{"type":3,"invoca')
	_check("a trailing partial frame is buffered, not parsed",
		partial["frames"].size() == 1 and partial["remainder"] == '{"type":3,"invoca')

	var empty_segment := PraxBusWire.split_frames(rs + '{"type":6}' + rs)
	_check("an empty segment is dropped", empty_segment["frames"].size() == 1)

	# invocationId is a STRING: SignalR matches completions on it by value.
	var join_frame: Dictionary = JSON.parse_string(
		PraxBusWire.build_invocation("1", "JoinBus", ["office:hq", null]))
	_eq("join targets JoinBus", join_frame["target"], "JoinBus")
	_eq("join sends an explicit null ticket", join_frame["arguments"], ["office:hq", null])
	_check("the invocation id is a string", join_frame["invocationId"] is String)

	# A REJECTION arrives inside a SUCCESSFUL completion. Code that only inspects SignalR's own
	# error field reports every denied join as a success.
	var denied := PraxBusWire.parse_bus_result(JSON.parse_string(
		'{"type":3,"invocationId":"3","result":{"ok":false,"error":"unknown_topic","peers":[]}}'))
	_check("a rejection is ok:false, not an error frame",
		denied["ok"] == false and denied["error"] == "unknown_topic"
			and denied["is_transport_error"] == false)

	var joined := PraxBusWire.parse_bus_result(JSON.parse_string(
		'{"type":3,"invocationId":"1","result":{"ok":true,"error":null,"peers":' +
		'[{"userId":"u1","event":"move","payload":{"x":1}}]}}'))
	_check("a join carries every peer's retained state",
		joined["ok"] and joined["peers"].size() == 1
			and joined["peers"][0]["event"] == "move")

	# Zero recipients means it went out and nobody was joined. Treating it as a failure makes
	# every empty room look broken.
	var published := PraxBusWire.parse_bus_result(JSON.parse_string(
		'{"type":3,"invocationId":"2","result":{"ok":true,"error":null,"recipients":0}}'))
	_check("zero recipients is success", published["ok"] and published["recipients"] == 0)

	# Godot parses every JSON number as a float, so a count arrives as 1.0 unless it is coerced.
	var counted := PraxBusWire.parse_bus_result(JSON.parse_string(
		'{"type":3,"invocationId":"2","result":{"ok":true,"recipients":3}}'))
	_check("the recipient count is an int, not a float",
		typeof(counted["recipients"]) == TYPE_INT and counted["recipients"] == 3)

	# LeaveBus is void: its result is literally null.
	var void_result := PraxBusWire.parse_bus_result(JSON.parse_string(
		'{"type":3,"invocationId":"7","result":null}'))
	_check("a void result is ok", void_result["ok"] and void_result["peers"].size() == 0)

	var hub_error := PraxBusWire.parse_bus_result(JSON.parse_string(
		'{"type":3,"invocationId":"9","error":"An unexpected error occurred."}'))
	_check("a hub fault is kept apart from a policy rejection",
		hub_error["ok"] == false and hub_error["is_transport_error"])

	# The workspace comes from the token; adding a segment to this path 404s.
	_eq("the hub has no workspace segment",
		PraxBusWire.negotiate_url("https://gw.test"),
		"https://gw.test/hubs/event-bus/negotiate?negotiateVersion=1")
	_eq("the socket url upgrades the scheme and carries the token",
		PraxBusWire.socket_url("https://gw.test", "abc"),
		"wss://gw.test/hubs/event-bus?access_token=abc")
	_check("a plaintext base url gives a plaintext socket url",
		PraxBusWire.socket_url("http://localhost:5000", "t").begins_with("ws://"))

	for code in ["invalid_bus_key", "unknown_topic", "denied", "invalid_ticket",
			"bus_full_or_too_many_buses", "not_a_member", "invalid_event_name",
			"payload_too_large", "rate_limited"]:
		_check("%s has a sentence worth reading" % code,
			PraxBusWire.describe_error(code).length() > 20)
