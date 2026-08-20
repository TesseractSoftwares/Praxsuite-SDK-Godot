## Classifies Praxsuite credentials and refuses to let a secret key reach game code.
##
## A Godot export is a .pck a player can open, so anything inside it is readable. A publishable
## key (pk_live_) is designed for that - it identifies the workspace and carries only the scopes
## an administrator granted. A secret key (sk_live_) carries full credential scope, and a player
## who extracts one gains that access.
##
## The check is unconditional. There is no opt-out flag, because every "just for testing"
## opt-out eventually ships.
class_name PraxKeyGuard
extends RefCounted

const PUBLISHABLE_PREFIX := "pk_live_"
const SECRET_PREFIX := "sk_live_"

enum Kind { UNKNOWN, PUBLISHABLE, SECRET, JWT }


static func classify(credential: String) -> Kind:
	if credential.is_empty():
		return Kind.UNKNOWN
	if credential.begins_with(SECRET_PREFIX):
		return Kind.SECRET
	if credential.begins_with(PUBLISHABLE_PREFIX):
		return Kind.PUBLISHABLE

	# A JWT is header.payload.signature - exactly two dots, no whitespace.
	if credential.count(".") == 2 and not credential.contains(" ") and not credential.contains("\n"):
		return Kind.JWT
	return Kind.UNKNOWN


## Returns a PraxError when the credential must not be used from game code, else null.
##
## GDScript cannot throw, so this returns the refusal rather than raising it - and the caller
## must check. Every entry point that accepts a credential does.
static func check_client_safe(credential: String, context: String) -> PraxError:
	if classify(credential) != Kind.SECRET:
		return null

	return PraxError.new("SECRET_KEY_IN_CLIENT",
		"Refusing to use a secret key (%s...) from game code in %s.\n\n" % [SECRET_PREFIX, context]
		+ "A Godot export is a .pck a player can open, so a secret key inside it is readable, "
		+ "and it carries full access to your workspace.\n\n"
		+ "Use a publishable key (%s...) here, and give each player their own identity with " % PUBLISHABLE_PREFIX
		+ "Prax.auth.login(). Row-level filters then scope every read and write to that player, "
		+ "server-side.\n\n"
		+ "If you need secret-key access, it belongs in a dedicated server build or a backend "
		+ "service reading the key from the environment - never in a client export.\n\n"
		+ "See SECURITY.md.")


## Masks a credential for logs. Keeps enough to identify which key was used, not its value.
static func redact(credential: String) -> String:
	if credential.is_empty():
		return "(none)"
	match classify(credential):
		Kind.JWT:
			return "(session token)"
		Kind.PUBLISHABLE, Kind.SECRET:
			# The prefix is public information; the entropy after it is not.
			return credential.substr(0, mini(credential.length(), PUBLISHABLE_PREFIX.length() + 4)) + "..."
		_:
			return "(redacted)"
