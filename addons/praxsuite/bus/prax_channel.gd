## A single bus - one topic, one instance. This is the object you actually work with.
##
## Connect to its signals before joining; they are kept across a reconnect, because the bus
## re-joins on your behalf and the same connections keep firing.
##
## [codeblock]
## var room := Prax.bus.topic("office").channel("hq")
## room.event_received.connect(_on_bus_event)
## room.peer_left.connect(_remove_avatar)
##
## for peer in await room.join():
##     _move_avatar(peer["user_id"], peer["payload"])
##
## await room.publish("move", {"x": x, "y": y})
## [/codeblock]
class_name PraxChannel
extends RefCounted

## An event from another peer: from_user_id is stamped by the server, never by the sender.
##
## payload is UNTRUSTED. The bus relays opaque JSON between USERS and parses none of it, so every
## server-side check is bypassed. A position is a hint, never an authority.
signal event_received(event_name: String, payload: Variant, from_user_id: String)

## Fires only when the topic has presence enabled.
signal peer_joined(user_id: String)
signal peer_left(user_id: String)

## The server removed this connection, because the topic was disabled or re-scoped while the
## socket was open. The SDK does not re-join: that would be arguing with a decision the server has
## just made.
signal evicted()

## The normalised key, e.g. "office:hq".
var key: String = ""

## Every peer's last retained message, as of the most recent join. An Array of
## { user_id, event, payload }.
##
## This is what stops a late joiner staring at an empty room until somebody moves. It is a
## snapshot, not a live view - what follows arrives through [signal event_received].
var peers: Array = []

## Only consulted for topics whose access mode is Ticket, and remembered so a reconnect can
## re-join with it. Ticket topics are not usable yet - nothing in the platform mints a ticket.
var ticket: String = ""

## Whether the app wants to be here. Drives the re-join after a reconnect.
var wanted := false
var joined := false

var _bus: Object = null


func _init(bus: Object, p_key: String) -> void:
	_bus = bus
	key = p_key


## The topic segment - everything before the first colon.
var topic: String:
	get:
		var i := key.find(":")
		return key if i < 0 else key.substr(0, i)


## The instance segment - everything after the first colon.
var instance: String:
	get:
		var i := key.find(":")
		return "" if i < 0 else key.substr(i + 1)


## Joins the bus. Returns the peers already present, or a PraxError.
##
## A refused join returns an error rather than an empty list, and it is worth checking: a publish
## that does not land is one dropped frame, whereas a join that does not land leaves this client
## silently absent for the whole session.
func join(p_ticket: String = "") -> Variant:
	wanted = true
	if not p_ticket.is_empty():
		ticket = p_ticket

	var result: Variant = await _bus.invoke("JoinBus", [key, ticket if not ticket.is_empty() else null])
	if result is PraxError:
		wanted = false
		return result

	if not result["ok"]:
		wanted = false
		var code := str(result["error"])
		return PraxError.new(
			"BUS_" + (code if not code.is_empty() else "denied").to_upper(),
			'Could not join "%s": %s' % [key, PraxBusWire.describe_error(code)])

	joined = true
	peers = result["peers"]
	return peers


## Sends an event to every OTHER peer in the bus.
##
## Returns { ok, error, recipients }. It does NOT report a refusal as an error, because dropping
## an ephemeral frame is ordinary operation and a game loop that treats a rate limit as a failure
## is worse than one that skips a frame:
##
## [codeblock]
## var r = await room.publish("move", {"x": x, "y": y})
## if not r["ok"]:
##     print(r["error"])        # e.g. "rate_limited"
## if r["recipients"] == 0:
##     pass                     # it went out, and nobody was joined
## [/codeblock]
##
## You will not receive your own event back. Apply your own change locally.
func publish(event_name: String, payload: Variant = {}) -> Variant:
	return await _bus.invoke("Publish", [key, event_name, payload])


## Leaves the bus. Idempotent, and it stops the reconnect logic re-joining.
func leave() -> void:
	wanted = false
	joined = false
	peers = []
	if _bus.is_connected_to_hub():
		await _bus.invoke("LeaveBus", [key])


func _dispatch(event_name: String, payload: Variant, from_user_id: String) -> void:
	event_received.emit(event_name, payload, from_user_id)


func _dispatch_peer(is_join: bool, user_id: String) -> void:
	if is_join:
		peer_joined.emit(user_id)
	else:
		peer_left.emit(user_id)


func _dispatch_evicted() -> void:
	wanted = false
	joined = false
	evicted.emit()
