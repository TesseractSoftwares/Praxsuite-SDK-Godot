## SDK logging. Every message passes through scrub(), so a credential cannot reach the Godot
## console, a log file, or a crash report a player might send you.
class_name PraxLog
extends RefCounted

enum Level { OFF, ERROR, WARNING, INFO, VERBOSE }

## Defaults to WARNING. Raise to VERBOSE to log request and response bodies - useful while
## developing, not in a shipped game.
static var minimum: Level = Level.WARNING

# Raw strings (r"...") matter here. In a normal GDScript string \b is a backspace character and
# \s is not an escape at all, so writing these as ordinary strings produced a parse error rather
# than the regex intended.
#
# Lookbehind rather than a capture group, so the replacement needs no back-reference: both
# prefixes are eight characters, which PCRE2 requires for an alternation inside a lookbehind.
const _KEY_RE := r"(?<=pk_live_|sk_live_)[A-Za-z0-9]{6,}"
const _JWT_RE := r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+"

## Fields whose values are secrets wherever they appear.
const _SECRET_FIELDS := [
	"refreshToken", "accessToken", "password", "newPassword", "currentPassword",
	"confirmPassword", "sessionToken", "publicKey",
]

static var _key_regex: RegEx
static var _jwt_regex: RegEx
static var _field_regexes: Array = []


static func _ensure_regexes() -> void:
	if _key_regex != null:
		return

	_key_regex = RegEx.new()
	_key_regex.compile(_KEY_RE)

	_jwt_regex = RegEx.new()
	_jwt_regex.compile(_JWT_RE)

	# One regex per field, each with a literal replacement. Rebuilding the field name from a
	# capture group meant tracking offsets by hand through a substr loop, which is the kind of
	# arithmetic that quietly stops scrubbing after the first match.
	for field in _SECRET_FIELDS:
		var re := RegEx.new()
		re.compile('"%s"\\s*:\\s*"[^"]*"' % field)
		_field_regexes.append([field, re])


## Removes credentials from a string. Public because callers building their own diagnostics
## should run untrusted text through it too.
static func scrub(text: String) -> String:
	if text.is_empty():
		return text
	_ensure_regexes()

	var out := _key_regex.sub(text, "<redacted>", true)
	out = _jwt_regex.sub(out, "<jwt redacted>", true)
	for pair in _field_regexes:
		out = pair[1].sub(out, '"%s":"<redacted>"' % pair[0], true)
	return out


static func _emit(level: Level, message: String) -> void:
	if level > minimum or minimum == Level.OFF:
		return

	var line := "[Praxsuite] " + scrub(message)
	match level:
		Level.ERROR:
			push_error(line)
		Level.WARNING:
			push_warning(line)
		_:
			print(line)


static func error(message: String) -> void: _emit(Level.ERROR, message)
static func warn(message: String) -> void: _emit(Level.WARNING, message)
static func info(message: String) -> void: _emit(Level.INFO, message)
static func verbose(message: String) -> void: _emit(Level.VERBOSE, message)
