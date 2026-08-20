## Quickstart: configure, sign in, write a row, read it back.
##
## Fill in the three constants below and run this scene. Everything it does is something a real
## game does on its first launch, in the order a real game does it.
##
## The workspace id is not a secret - /auth/config is unauthenticated, so it cannot be one - but
## it is not something to publish either. Keep your real one out of a public repository.
extends Node

const WORKSPACE_ID := "PUT-YOUR-WORKSPACE-ID-HERE"
const PUBLISHABLE_KEY := "pk_live_PUT-YOURS-HERE"

## The table this sample reads and writes. Create it in your workspace with a `Slot` (Number) and
## a `Level` (Number) column, and grant your credential access to it.
const TABLE := "Saves"

const EMAIL := "player@example.com"
const PASSWORD := "put-a-test-password-here"


func _ready() -> void:
	# Raise the log level so you can watch the requests while trying this out. Leave this out of
	# a shipped game: VERBOSE logs request and response bodies.
	PraxLog.minimum = PraxLog.Level.VERBOSE

	var problem := Prax.configure(WORKSPACE_ID, PUBLISHABLE_KEY)
	if problem != null:
		push_error(str(problem))
		return

	# Being told the session ended, rather than discovering it on the next save.
	Prax.auth.session_expired.connect(func() -> void:
		print("Session expired - send the player back to the title screen here."))

	await _sign_in()


func _sign_in() -> void:
	print("Signing in...")
	var result: Variant = await Prax.auth.login(EMAIL, PASSWORD)

	if result is PraxError:
		# A first run has no account yet, so 401 here is expected rather than exceptional.
		if result.is_auth_failure:
			print("No account yet - registering.")
			await _register()
			return
		push_error("Could not sign in: %s" % result)
		return

	print("Signed in as %s" % Prax.auth.session.display_name)
	await _use_the_backend()


func _register() -> void:
	var result: Variant = await Prax.auth.register(EMAIL, PASSWORD, {"displayName": "Test Player"})
	if result is PraxError:
		push_error("Could not register: %s" % result)
		return

	# Not a failure. When a workspace requires email confirmation, register succeeds and issues no
	# session. Reporting this as a bad password would leave the player retrying a correct one
	# forever.
	if result.requires_email_confirmation:
		print("Registered. Confirm the address in your inbox, then sign in.")
		return

	print("Registered and signed in as %s" % Prax.auth.session.display_name)
	await _use_the_backend()


func _use_the_backend() -> void:
	# ── Write ────────────────────────────────────────────────────────────────
	# Note what is NOT here: an owner or player-id column. If the table is configured for
	# per-player isolation, the gateway stamps ownership from this player's verified token and
	# rejects a request that tries to set it. That rejection is the anti-tamper guarantee.
	var written: Variant = await Prax.data.insert(TABLE, {"Slot": 1, "Level": 12})
	if written is PraxError:
		push_error("Insert failed: %s" % written)
		return
	print("Wrote row %s" % written.row.get("ID", "?"))

	# ── Read back ────────────────────────────────────────────────────────────
	var page: Variant = await Prax.data.table(TABLE) \
		.select(["ID", "Slot", "Level"]) \
		.where([PraxFilter.gte("Level", 1)]) \
		.order_by_descending("Level") \
		.limit(10) \
		.with_total_count() \
		.fetch()

	if page is PraxError:
		push_error("Query failed: %s" % page)
		return

	print("Got %d of %d rows" % [page.rows.size(), page.total])
	for row in page.rows:
		# int(), because Godot decodes every JSON number as a float: Level arrives as 12.0.
		print("  slot %d -> level %d" % [int(row["Slot"]), int(row["Level"])])

	# ── Update ───────────────────────────────────────────────────────────────
	var row_id := str(written.row.get("ID", ""))
	if not row_id.is_empty():
		var updated: Variant = await Prax.data.update_by_id(TABLE, row_id, {"Level": 13})
		if updated is PraxError:
			push_error("Update failed: %s" % updated)
		else:
			print("Updated %d row(s)" % updated.affected_rows)

	# ── Server-authoritative work ────────────────────────────────────────────
	# Anything a player must not be able to influence goes here instead of into a table write.
	# The game asks for an outcome; the automation behind the endpoint decides it.
	#
	#   var result = await Prax.endpoints.call_endpoint("submit-score", {"score": 4200})

	print("Done.")
