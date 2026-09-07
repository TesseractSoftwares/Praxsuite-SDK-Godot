## Player accounts: register, sign in, refresh, sign out, password reset.
##
## Reached through the client: `Prax.auth`.
##
## Every method returns either its result or a PraxError - GDScript has no exceptions, so check
## with `is PraxError`:
##
## [codeblock]
## var result = await Prax.auth.login("player@example.com", password)
## if result is PraxError:
##     show_message(result.message)
##     return
## print("Signed in as ", Prax.auth.session.display_name)
## [/codeblock]
##
## Auth routes skip table-scope checks, so register/login/refresh work on a credential with no
## table scopes at all. That is the credential a shipped game should carry.
class_name PraxAuth
extends RefCounted

## Emitted whenever the signed-in user changes, including on sign-out (session is null then).
signal session_changed(session: PraxSession)

## Emitted when a refresh fails permanently and the player has been signed out. Send them back
## to your title screen from here rather than discovering it on the next query.
signal session_expired()

## Internal: lets concurrent refresh callers wait on the single in-flight request.
signal _refresh_completed(result: Variant)


## Register succeeded, but whether a session came with it depends on the workspace.
class RegistrationResult extends RefCounted:
	## Set when the workspace requires email confirmation. There is NO session in that case, and
	## this is not a failure - telling the player their password was wrong would leave them
	## retrying a correct one forever.
	var requires_email_confirmation: bool = false

	## Null when confirmation is required.
	var session: PraxSession = null

	var message: String = ""


var _client: Object  # PraxsuiteClient; untyped to avoid a cyclic class reference.
var _store: Object   # PraxSessionStore.Memory or .EncryptedFile
var _session: PraxSession = null
var _refresh_in_flight := false


func _init(client: Object, store: Object) -> void:
	_client = client
	_store = store
	var restored: PraxSession = _store.load_session()
	if restored != null and restored.is_valid:
		_session = restored


## The signed-in user, or null.
var session: PraxSession:
	get: return _session

var is_signed_in: bool:
	get: return _session != null and _session.is_valid


# ─────────────────────────────────────────────────────────────────────────────
# Sign in and out

## Creates an account. Check `requires_email_confirmation` on the result before assuming the
## player is signed in.
func register(email: String, password: String, extra_fields: Dictionary = {}) -> Variant:
	var body := {"email": email, "password": password}
	for key in extra_fields:
		body[key] = extra_fields[key]

	var payload: Variant = await _post("register", body)
	if payload is PraxError:
		return payload

	var result := RegistrationResult.new()
	result.message = str(payload.get("message", ""))
	result.requires_email_confirmation = bool(payload.get("requiresEmailConfirmation", false))

	if not result.requires_email_confirmation and payload.has("accessToken"):
		result.session = _adopt(PraxSession.from_payload(payload))

	return result


func login(email: String, password: String) -> Variant:
	var payload: Variant = await _post("login", {"email": email, "password": password})
	if payload is PraxError:
		return payload
	return _adopt(PraxSession.from_payload(payload))


## Signs out and clears the stored session. The local session is cleared even if the server call
## fails - a player who pressed "sign out" must end up signed out.
func logout() -> Variant:
	var had_token := _session != null and not _session.refresh_token.is_empty()
	var outcome: Variant = null
	if had_token:
		outcome = await _post("logout", {"refreshToken": _session.refresh_token})

	_session = null
	_store.clear()
	session_changed.emit(null)

	return outcome if outcome is PraxError else true


# ─────────────────────────────────────────────────────────────────────────────
# Session maintenance

## Refreshes if the access token is close to expiry. Called automatically before every request,
## so you should not normally need it.
##
## Concurrent callers share ONE request. The gateway retires the old refresh token as it issues
## the new one, so two racing refreshes would leave the loser holding a token the server has
## already invalidated.
func ensure_fresh_session() -> Variant:
	if _session == null or not _session.is_valid:
		return true
	if not _session.needs_refresh:
		return true

	if _refresh_in_flight:
		return await _refresh_completed

	_refresh_in_flight = true
	var result: Variant = await _refresh_now()
	_refresh_in_flight = false
	_refresh_completed.emit(result)
	return result


func _refresh_now() -> Variant:
	if _session.refresh_token.is_empty():
		_expire()
		return PraxError.new("SESSION_EXPIRED",
			"The session expired and there is no refresh token, so the player has been signed out.", 401)

	var payload: Variant = await _post("refresh", {"refreshToken": _session.refresh_token})
	if payload is PraxError:
		var err: PraxError = payload
		# A rejected refresh token is final. A network blip is not - keep the session so the
		# player is not signed out because their wifi dropped for a second.
		if err.is_auth_failure:
			_expire()
		return err

	return _adopt(PraxSession.from_payload(payload, _session))


func _expire() -> void:
	_session = null
	_store.clear()
	session_changed.emit(null)
	session_expired.emit()


func _adopt(new_session: PraxSession) -> PraxSession:
	_session = new_session
	_store.save_session(new_session)
	session_changed.emit(new_session)
	return new_session


# ─────────────────────────────────────────────────────────────────────────────
# Password reset and confirmation
#
# These always report success, whether or not the address exists. That is deliberate on the
# server's part: it stops the endpoint being used to discover which addresses have accounts.
# Do not "helpfully" tell the player no such account exists - that reintroduces the leak.

func forgot_password(email: String) -> Variant:
	var payload: Variant = await _post("forgot-password", {"email": email})
	return payload if payload is PraxError else true


func verify_reset_code(email: String, code: String) -> Variant:
	var payload: Variant = await _post("verify-reset-code", {"email": email, "code": code})
	return payload if payload is PraxError else true


func reset_password(email: String, code: String, new_password: String) -> Variant:
	var payload: Variant = await _post("reset-password",
		{"email": email, "code": code, "newPassword": new_password})
	return payload if payload is PraxError else true


func resend_confirmation(email: String) -> Variant:
	var payload: Variant = await _post("resend-confirmation", {"email": email})
	return payload if payload is PraxError else true


# ─────────────────────────────────────────────────────────────────────────────

## Reads the workspace's public auth configuration: sign-in methods, branding, and the current
## publishable key.
##
## This route is UNAUTHENTICATED. A workspace id alone is enough to fetch it, which is why a
## workspace id is not a secret - but also why it does not belong in a public code sample.
func get_config() -> Variant:
	var url := PraxRoutes.auth(_client.base_url, _client.workspace_id, "config")
	var response: Variant = await _client.http.request_json(
		HTTPClient.METHOD_GET, url, _client.anonymous_headers(), null, true)
	if response is PraxError:
		return response
	return PraxResult.unwrap_envelope(response)


## The external identity providers this workspace has configured.
##
## Returns an Array of { slug, display_name }, or a PraxError.
##
## Read from oidcProviders in the public config. authPageConfig.enabledSocialProviders is a
## different list, written by the portal's auth-page designer - a provider named there but absent
## here is not configured, and its button is a dead end.
func providers() -> Variant:
	var config: Variant = await get_config()
	if config is PraxError:
		return config

	var raw: Variant = config.get("oidcProviders")
	if not (raw is Array):
		return []

	var found := []
	for item in raw:
		if item is String and not (item as String).is_empty():
			found.append({"slug": item, "display_name": item})
		elif item is Dictionary:
			var slug := str((item as Dictionary).get("slug", ""))
			if not slug.is_empty():
				var label := str((item as Dictionary).get("displayName", ""))
				found.append({
					"slug": slug,
					"display_name": label if not label.is_empty() else slug,
				})
	return found


## Starts a sign-in with an external identity provider.
##
## Returns { authorization_url, state }, or a PraxError. Open the URL with OS.shell_open(); the
## provider sends the player back to the redirect URI configured for it in the portal, carrying
## code and state. Hand all of it to complete_oidc_login().
##
## Only the authorization-code flow exists - there is no route that accepts a provider's own
## id_token - so even a native button has to make this browser hop.
func start_oidc_login(provider_slug: String) -> Variant:
	var slug := provider_slug.strip_edges()
	if slug.is_empty():
		return PraxError.new("INVALID_ARGUMENT", "provider_slug is required.")

	var url := PraxRoutes.auth(_client.base_url, _client.workspace_id, "oidc/" + slug.uri_encode())
	var response: Variant = await _client.http.request_json(
		HTTPClient.METHOD_GET, url, _client.anonymous_headers(), null, true)
	if response is PraxError:
		return response

	var payload: Dictionary = PraxResult.unwrap_envelope(response)
	var authorization_url := str(payload.get("authorizationUrl", payload.get("url", "")))
	if authorization_url.is_empty():
		return PraxError.new("OIDC_NO_URL",
			'The gateway returned no authorization URL for provider "%s". Check that it is '
				% provider_slug + "configured and enabled for this workspace.")

	return {
		"authorization_url": authorization_url,
		"state": str(payload.get("state", "")),
	}


## Exchanges the provider's code for a Praxsuite session.
##
## All four values are required by the gateway, and three of them are why this call fails when it
## fails. provider_slug scopes the one-time state, so omitting it makes every callback look
## expired. state is consumed once; reusing or skipping it is rejected. redirect_uri is compared
## against the value configured for that provider and must match exactly - pass the URI you were
## actually redirected to rather than rebuilding it, which is how it ends up differing by a
## trailing slash and failing with a message about redirect URIs that nobody can act on.
##
## The session is stored exactly as a password login stores it, so refresh, sign-out and every
## authenticated call behave identically afterwards.
func complete_oidc_login(provider_slug: String, code: String, state: String,
		redirect_uri: String) -> Variant:

	if provider_slug.strip_edges().is_empty():
		return PraxError.new("INVALID_ARGUMENT", "provider_slug is required.")
	if code.strip_edges().is_empty():
		return PraxError.new("INVALID_ARGUMENT", "code is required.")
	if state.strip_edges().is_empty():
		return PraxError.new("INVALID_ARGUMENT", "state is required.")
	if redirect_uri.strip_edges().is_empty():
		return PraxError.new("INVALID_ARGUMENT", "redirect_uri is required.")

	var payload: Variant = await _post("oidc/callback", {
		"providerSlug": provider_slug,
		"code": code,
		"state": state,
		"redirectUri": redirect_uri,
	})
	if payload is PraxError:
		return payload

	return _adopt(PraxSession.from_payload(payload))


func _post(action: String, body: Dictionary) -> Variant:
	var url := PraxRoutes.auth(_client.base_url, _client.workspace_id, action)
	# Auth calls carry the credential, never the session - signing in while already signed in
	# must not depend on the old token still being valid.
	var response: Variant = await _client.http.request_json(
		HTTPClient.METHOD_POST, url, _client.anonymous_headers(), body, false)
	if response is PraxError:
		return response
	return PraxResult.unwrap_envelope(response)
