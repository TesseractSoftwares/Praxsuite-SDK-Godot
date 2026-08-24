## The Praxsuite client. Registered as the `Prax` autoload, so it is reachable from anywhere:
##
## [codeblock]
## func _ready() -> void:
##     Prax.configure("your-workspace-id", "pk_live_...")
##
##     var result = await Prax.auth.login(email, password)
##     if result is PraxError:
##         return
##
##     var page = await Prax.data.table("Saves").where_eq("Slot", 1).fetch()
## [/codeblock]
##
## This is a Node because Godot's HTTPRequest is a Node and needs a parent in the scene tree.
##
## ─────────────────────────────────────────────────────────────────────────────
## What belongs in a shipped game
##
## A publishable key (pk_live_). It identifies the workspace and nothing more: the server decides
## what it may touch, through the table scopes you configure. A secret key (sk_live_) is refused
## here with no opt-out, because a key shipped inside a game binary is a key every player has.
##
## Be aware that every credential carries BOTH halves - there is no publishable-only credential -
## so whatever tables you scope to the client credential are reachable by anyone who has the
## workspace id. Give the client credential the narrowest scopes that let your game work, and
## keep anything sensitive on a credential the game never sees.
class_name PraxsuiteClient
extends Node

const SDK_VERSION := "1.0.0"

signal configured()

var workspace_id: String = ""
var base_url: String = ""

var auth: PraxAuth = null
var data: PraxData = null
var schema: PraxSchema = null
var endpoints: PraxEndpoints = null
var http: PraxHttp = null

var _credential: String = ""
var _configured := false
var _retried_after_refresh := false


func _ready() -> void:
	# Requests must survive a paused game: a player who opens a pause menu should still be able
	# to save.
	process_mode = Node.PROCESS_MODE_ALWAYS


## Points the client at a workspace. Call once, early - `_ready` on your first scene is the usual
## place.
##
## `base_url` defaults to the Praxsuite cloud gateway. Pass your own for a dedicated tier or a
## local backend.
func configure(p_workspace_id: String, credential: String,
		p_base_url: String = PraxRoutes.CLOUD_HOST,
		session_store: Object = null, timeout_seconds: float = 20.0) -> PraxError:

	if p_workspace_id.strip_edges().is_empty():
		return _fail("MISSING_WORKSPACE", "A workspace id is required.")
	if credential.strip_edges().is_empty():
		return _fail("MISSING_CREDENTIAL",
			"A publishable key is required. Create one in your workspace under API Gateway.")

	# The single most important check in this SDK. There is no flag to skip it.
	var unsafe := PraxKeyGuard.check_client_safe(credential.strip_edges(), "Prax.configure()")
	if unsafe != null:
		return _fail(unsafe.code, unsafe.message)

	workspace_id = p_workspace_id.strip_edges()
	_credential = credential.strip_edges()
	base_url = PraxRoutes.normalize_base_url(p_base_url)

	if PraxRoutes.is_insecure_remote(base_url):
		# Not fatal - a LAN test server is a legitimate thing to point at - but a plaintext
		# connection puts the session token on the wire for anyone on the network to read.
		PraxLog.warn("%s is plaintext HTTP. Session tokens will travel unencrypted; use https for anything but local testing." % base_url)

	http = PraxHttp.new(self, timeout_seconds)
	auth = PraxAuth.new(self, session_store if session_store != null else PraxSessionStore.Memory.new())
	data = PraxData.new(self)
	schema = PraxSchema.new(self)
	endpoints = PraxEndpoints.new(self)

	_configured = true
	PraxLog.info("Configured for workspace %s at %s (SDK %s)" % [workspace_id, base_url, SDK_VERSION])
	configured.emit()
	return null


var is_configured: bool:
	get: return _configured


## Headers for a call that must NOT carry the player's session: sign-in, and the unauthenticated
## config route.
func anonymous_headers() -> Dictionary:
	return {
		"x-api-key": _credential,
		"x-praxsuite-sdk": "godot/%s" % SDK_VERSION,
	}


## Headers for everything else. The player's session takes precedence when there is one, so
## row filters and role scopes apply to them rather than to the anonymous credential.
func session_headers() -> Dictionary:
	var headers := {"x-praxsuite-sdk": "godot/%s" % SDK_VERSION}
	if auth != null and auth.is_signed_in:
		# The gateway accepts either header, never both: Authorization carries a session token,
		# x-api-key carries a key.
		headers["Authorization"] = "Bearer " + auth.session.access_token
	else:
		headers["x-api-key"] = _credential
	return headers


## Sends an authorised request, refreshing the session first if it is close to expiry.
##
## A 401 on a signed-in request is retried once after a refresh: an access token can expire
## between the check and the server reading it.
func send(method: int, url: String, body: Variant = null, retry_safe: bool = false,
		timeout_override: float = -1.0) -> Variant:
	if not _configured:
		return PraxError.new("NOT_CONFIGURED",
			"Call Prax.configure(workspace_id, publishable_key) before using the SDK.")

	if auth != null and auth.is_signed_in:
		var refreshed: Variant = await auth.ensure_fresh_session()
		# A failed refresh is worth reporting only when it signed the player out. A network blip
		# leaves the old token in place, and it may still work.
		if refreshed is PraxError and not auth.is_signed_in:
			return refreshed

	var response: Variant = await http.request_json(method, url, session_headers(), body, retry_safe, timeout_override)

	if response is PraxError and response.is_auth_failure and auth != null and auth.is_signed_in \
			and not _retried_after_refresh:
		_retried_after_refresh = true
		var again: Variant = await auth._refresh_now()
		_retried_after_refresh = false
		if not (again is PraxError):
			return await http.request_json(method, url, session_headers(), body, retry_safe, timeout_override)

	return response


func _fail(code: String, message: String) -> PraxError:
	# A misconfiguration is a programming mistake, not a runtime condition, so it is worth being
	# loud about in the editor as well as returning.
	PraxLog.error(message)
	return PraxError.new(code, message)
