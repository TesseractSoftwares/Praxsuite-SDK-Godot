## Every failure the gateway reports arrives as a PraxError.
##
## GDScript has no exceptions, so errors are returned rather than thrown. Every SDK call
## returns either its result or a PraxError, and `is PraxError` tells them apart:
##
## [codeblock]
## var save = await Prax.data.from("Saves").first()
## if save is PraxError:
##     if save.is_rate_limited: ...
##     return
## [/codeblock]
##
## The `code` is stable and safe to branch on; `message` is human-facing and may change.
class_name PraxError
extends RefCounted

## Stable machine-readable code, e.g. RATE_LIMIT_EXCEEDED, FORBIDDEN, NETWORK_ERROR.
var code: String = "UNKNOWN"

## HTTP status, or 0 for transport failures that never reached the gateway.
var status: int = 0

var message: String = ""

## Per-field validation details, when the gateway supplied them.
var details: PackedStringArray = PackedStringArray()

## Raw response body, kept for diagnostics. Never contains your API key.
var raw_body: String = ""


func _init(p_code: String = "UNKNOWN", p_message: String = "", p_status: int = 0,
		p_details: PackedStringArray = PackedStringArray(), p_raw_body: String = "") -> void:
	code = p_code
	message = p_message
	status = p_status
	details = p_details
	raw_body = p_raw_body


## The credential is missing, malformed, expired, or the session needs a refresh.
var is_auth_failure: bool:
	get: return status == 401

## Authenticated, but this credential or role is not scoped for the operation.
var is_forbidden: bool:
	get: return status == 403

## Too many calls per minute. Backing off and retrying will succeed.
var is_rate_limited: bool:
	get: return code == "RATE_LIMIT_EXCEEDED"

## A plan allowance is exhausted. Retrying will NOT help - the workspace owner has to upgrade.
## Shares HTTP 429 with a rate limit, which is exactly why this is a separate check.
var is_quota_exceeded: bool:
	get: return code == "QUOTA_EXCEEDED" or code == "EGRESS_LIMIT_EXCEEDED"

## Transport failure: offline, DNS, TLS, or timeout.
var is_network_error: bool:
	get: return code == "NETWORK_ERROR" or code == "TIMEOUT"

## Worth retrying automatically. Quota exhaustion deliberately is not.
var is_transient: bool:
	get:
		if is_quota_exceeded:
			return false
		return is_network_error or is_rate_limited or (status >= 500 and status <= 599)


func _to_string() -> String:
	var s := "[Praxsuite] " + code
	if status > 0:
		s += " (HTTP %d)" % status
	s += ": " + message
	if not details.is_empty():
		s += "\n  - " + "\n  - ".join(details)
	return s
