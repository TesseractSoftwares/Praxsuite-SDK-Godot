## A signed-in user's session, plus where to keep it between launches.
##
## Sessions live in memory by default. Persisting one means writing a refresh token to the
## player's disk, which is a deliberate trade you opt into rather than a default you inherit:
## see PraxSessionStore below for what the encryption does and does not protect against.
class_name PraxSession
extends RefCounted

var access_token: String = ""
var refresh_token: String = ""

## When the access token stops being accepted. Unix seconds, UTC.
var expires_at_unix: int = 0

var user_id: String = ""
var email: String = ""
var display_name: String = ""

## Any additional profile fields the workspace returns. Kept verbatim so a refresh can carry
## them forward - a refresh response does not always repeat the user block, and dropping it
## makes the player's identity vanish mid-session.
var profile: Dictionary = {}


var is_valid: bool:
	get: return not access_token.is_empty()


## True once the access token has expired. A refresh is due.
var is_expired: bool:
	get:
		if expires_at_unix <= 0:
			return false
		return Time.get_unix_time_from_system() >= float(expires_at_unix)


## True shortly BEFORE expiry, so a refresh happens between requests rather than in the middle
## of one. Sixty seconds covers a slow mobile round trip.
var needs_refresh: bool:
	get:
		if expires_at_unix <= 0:
			return false
		return Time.get_unix_time_from_system() >= float(expires_at_unix) - 60.0


static func from_payload(payload: Dictionary, previous: PraxSession = null) -> PraxSession:
	var s := PraxSession.new()
	s.access_token = str(payload.get("accessToken", ""))
	s.refresh_token = str(payload.get("refreshToken", ""))

	# The gateway reports a lifetime in seconds; an absolute instant is what callers need.
	var expires_in := int(payload.get("expiresIn", 0))
	if expires_in > 0:
		s.expires_at_unix = int(Time.get_unix_time_from_system()) + expires_in
	elif payload.has("expiresAt"):
		s.expires_at_unix = int(Time.get_unix_time_from_datetime_string(str(payload["expiresAt"])))

	var user: Dictionary = payload.get("user", {}) if payload.get("user") is Dictionary else {}
	s.user_id = str(user.get("id", user.get("userId", "")))
	s.email = str(user.get("email", ""))
	s.display_name = str(user.get("displayName", user.get("name", "")))
	s.profile = user.duplicate(true)

	# A refresh carries tokens but not always the user block. Carry the old identity forward
	# rather than presenting a signed-in player as anonymous.
	if previous != null:
		if s.user_id.is_empty(): s.user_id = previous.user_id
		if s.email.is_empty(): s.email = previous.email
		if s.display_name.is_empty(): s.display_name = previous.display_name
		if s.profile.is_empty(): s.profile = previous.profile.duplicate(true)
		if s.refresh_token.is_empty(): s.refresh_token = previous.refresh_token

	return s


func to_dictionary() -> Dictionary:
	return {
		"accessToken": access_token,
		"refreshToken": refresh_token,
		"expiresAtUnix": expires_at_unix,
		"user": profile,
	}


static func from_dictionary(d: Dictionary) -> PraxSession:
	var s := PraxSession.new()
	s.access_token = str(d.get("accessToken", ""))
	s.refresh_token = str(d.get("refreshToken", ""))
	s.expires_at_unix = int(d.get("expiresAtUnix", 0))
	var user: Dictionary = d.get("user", {}) if d.get("user") is Dictionary else {}
	s.profile = user
	s.user_id = str(user.get("id", user.get("userId", "")))
	s.email = str(user.get("email", ""))
	s.display_name = str(user.get("displayName", user.get("name", "")))
	return s
