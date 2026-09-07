## The Prax Event Bus - ephemeral realtime between connected players.
##
## Avatars, cursors, "is typing", a lobby: state that is CHANGING, where losing a message is fine
## because a newer one is 100ms behind it.
##
## [codeblock]
## await Prax.auth.login(email, password)      # the bus needs a signed-in player, not the key
##
## var room := Prax.bus.topic("office").channel("hq")
## room.event_received.connect(func(name, payload, from): _move_avatar(from, payload))
##
## for peer in await room.join():
##     _move_avatar(peer["user_id"], peer["payload"])
##
## await room.publish("move", {"x": x, "y": y})
## [/codeblock]
##
## NOTHING IS PERSISTED. No history, no retry, no delivery to a player who was not connected. The
## test is one question: if this is lost, does it matter? Yes - a purchase, a score, an inventory
## grant - means a table or an automation, and a server-authoritative one at that. No, because a
## newer one is coming, means the bus.
##
## PAYLOADS ARE HOSTILE. The bus relays opaque JSON between PLAYERS and parses none of it, so every
## server-side check is bypassed. A position is a hint, never an authority.
##
## Publish DECISIONS, not frames. One message per movement decision rather than one per rendered
## frame: a two-second walk becomes one message instead of a hundred, and the receiver
## interpolates. The rate limit is priced by RECIPIENTS, so a busy room exhausts it far faster
## than an empty one.
class_name PraxBus
extends Node

## Where the connection is: "disconnected", "connecting", "connected" or "reconnecting".
signal state_changed(state: String)

const CALL_TIMEOUT_SECONDS := 30.0

## Reconnect automatically and re-join every bus that was held.
var auto_reconnect := true
var reconnect_delay_seconds := 1.0
var max_reconnect_delay_seconds := 30.0

var state: String = "disconnected"

var _client: Object = null
var _socket: WebSocketPeer = null
var _channels: Dictionary = {}          # normalised key -> PraxChannel
var _pending: Dictionary = {}           # invocation id -> parsed result, once it arrives
var _buffer: String = ""
var _next_invocation := 0
var _handshake_done := false
var _closed_by_us := false
var _reconnect_delay := 0.0
var _reconnect_at := 0.0
var _warned_about_routing := false


func _init(client: Object = null) -> void:
	_client = client
	name = "PraxBus"


func _ready() -> void:
	# The socket must keep being polled while the game is paused, or a pause menu silently drops
	# every peer.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)


func is_connected_to_hub() -> bool:
	return state == "connected"


## A topic by key. Nothing is sent until one of its channels is joined.
func topic(key: String) -> PraxTopic:
	return PraxTopic.new(self, PraxBusWire.normalize_bus_key(key))


## A channel by full key, "topic:instance". Repeated calls return the SAME object, so signal
## connections made anywhere in the game all fire.
##
## Returns a PraxError for a malformed key.
func channel(bus_key: String) -> Variant:
	var invalid := PraxBusWire.check_bus_key(bus_key)
	if invalid != null:
		return invalid

	var key := PraxBusWire.normalize_bus_key(bus_key)
	if not _channels.has(key):
		_channels[key] = PraxChannel.new(self, key)
	return _channels[key]


## The player's own private bus.
##
## Addressed as "user:self" and resolved server-side to their id - which is what makes it the one
## bus needing no ticket, since it cannot name anybody else. Use it to reach one player across
## their open clients.
func self_channel() -> Variant:
	return channel("user:self")


## Opens the connection. join() calls this for you; call it directly to fail fast at start-up.
## Returns a PraxError on failure, or null.
func connect_to_hub() -> Variant:
	if state == "connected":
		return null

	var session: Object = _client.auth.session if _client != null and _client.auth != null else null
	if session == null or not session.is_valid:
		return PraxError.new("BUS_REQUIRES_SESSION",
			"The Event Bus needs a signed-in player - it authenticates with the session token, "
			+ "not with the workspace key. Call Prax.auth.login() first.")

	_closed_by_us = false
	_set_state("connecting" if state == "disconnected" else "reconnecting")

	_socket = WebSocketPeer.new()
	_handshake_done = false
	_buffer = ""

	var url := PraxBusWire.socket_url(_client.base_url, session.access_token)
	var opened := _socket.connect_to_url(url)
	if opened != OK:
		_socket = null
		_set_state("disconnected")
		return PraxError.new("BUS_CONNECT_FAILED",
			"Could not open the Event Bus connection to %s (error %d)." % [_client.base_url, opened])

	# WebSocketPeer only advances while it is polled, and poll happens in _process.
	var deadline := Time.get_unix_time_from_system() + 15.0
	while state != "connected":
		if Time.get_unix_time_from_system() > deadline:
			_drop_connection()
			return PraxError.new("BUS_CONNECT_FAILED",
				"The Event Bus handshake did not complete within 15s. The commonest cause is an "
				+ "expired or rejected session token.")
		if _socket == null:
			return PraxError.new("BUS_CONNECT_FAILED",
				"The Event Bus connection closed during the handshake.")
		await get_tree().process_frame

	await _rejoin_all()
	return null


## Closes the connection and stops reconnecting. Channels keep their signal connections.
func disconnect_from_hub() -> void:
	_closed_by_us = true
	for c in _channels.values():
		c.wanted = false
		c.joined = false

	if _socket != null:
		_socket.close()
		_socket = null

	_set_state("disconnected")


## Sends one invocation and waits for its completion. Returns the parsed result, or a PraxError.
func invoke(target: String, args: Array) -> Variant:
	if state != "connected":
		var failure: Variant = await connect_to_hub()
		if failure is PraxError:
			return failure

	if _socket == null:
		return PraxError.new("BUS_NOT_CONNECTED", "The Event Bus connection is not open.")

	_next_invocation += 1
	var invocation_id := str(_next_invocation)
	_pending[invocation_id] = null

	_socket.send_text(PraxBusWire.frame(
		PraxBusWire.build_invocation(invocation_id, target, args)))

	var deadline := Time.get_unix_time_from_system() + CALL_TIMEOUT_SECONDS
	while _pending.get(invocation_id) == null:
		if _socket == null:
			_pending.erase(invocation_id)
			return PraxError.new("BUS_DISCONNECTED",
				"The connection closed before %s completed." % target)
		if Time.get_unix_time_from_system() > deadline:
			_pending.erase(invocation_id)
			return PraxError.new("BUS_TIMEOUT",
				"The hub did not answer %s within %ds." % [target, int(CALL_TIMEOUT_SECONDS)])
		await get_tree().process_frame

	var result: Variant = _pending[invocation_id]
	_pending.erase(invocation_id)
	return result


func _process(_delta: float) -> void:
	if _socket == null:
		_maybe_reconnect()
		return

	_socket.poll()

	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _handshake_done:
				_socket.send_text(PraxBusWire.frame(PraxBusWire.HANDSHAKE_FRAME))
				_handshake_done = true

			while _socket.get_available_packet_count() > 0:
				_receive(_socket.get_packet().get_string_from_utf8())

		WebSocketPeer.STATE_CLOSED:
			var code := _socket.get_close_code()
			_socket = null
			PraxLog.info("Event Bus connection closed (code %d)." % code)
			_on_closed()


func _receive(text: String) -> void:
	var split := PraxBusWire.split_frames(_buffer + text)
	_buffer = split["remainder"]
	for f in split["frames"]:
		_handle_frame(f)


func _handle_frame(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		PraxLog.warn("Discarded an Event Bus frame that is not a JSON object.")
		return

	var message: Dictionary = parsed

	# The first frame is the handshake answer: {} on success, { error } on failure.
	if state != "connected":
		if message.has("error"):
			PraxLog.error("The hub rejected the handshake: " + str(message["error"]))
			_drop_connection()
			return
		_reconnect_delay = 0.0
		_set_state("connected")
		return

	var kind := int(message.get("type", 0))

	if kind == PraxBusWire.MSG_PING:
		return  # keepalive - never surface it

	if kind == PraxBusWire.MSG_COMPLETION:
		var invocation_id := str(message.get("invocationId", ""))
		if _pending.has(invocation_id):
			_pending[invocation_id] = PraxBusWire.parse_bus_result(message)
		return

	if kind == PraxBusWire.MSG_INVOCATION:
		_handle_server_event(message)
		return

	if kind == PraxBusWire.MSG_CLOSE:
		PraxLog.warn("The hub closed the connection: " + str(message.get("error", "no reason given")))


func _handle_server_event(message: Dictionary) -> void:
	var target := str(message.get("target", ""))
	var args: Variant = message.get("arguments")
	var first: Dictionary = {}
	if args is Array and (args as Array).size() > 0 and (args as Array)[0] is Dictionary:
		first = (args as Array)[0]

	match target:
		"bus-event":
			for c in _route(first):
				c._dispatch(
					str(first.get("event", "")),
					first.get("payload"),
					str(first.get("fromUserId", "")))
		"peer-joined", "peer-left":
			var user_id := str(first.get("userId", ""))
			for c in _route(first):
				c._dispatch_peer(target == "peer-joined", user_id)
		"bus-evicted":
			var key := PraxBusWire.normalize_bus_key(str(first.get("bus", "")))
			if _channels.has(key):
				_channels[key]._dispatch_evicted()
		_:
			PraxLog.verbose("Ignoring an unknown Event Bus message: " + target)


## Decides which channels an inbound message belongs to.
##
## The message names its bus, and that is the whole answer. The fallback exists because a gateway
## older than 2026-09-07 does not send the field: one connection carries every joined bus, and
## SignalR reports which invocation arrived but never which group it came from, so on such a
## server a client holding two buses genuinely cannot tell their traffic apart.
func _route(message: Dictionary) -> Array:
	var named := PraxBusWire.normalize_bus_key(str(message.get("bus", "")))
	if not named.is_empty():
		return [_channels[named]] if _channels.has(named) else []

	var joined := []
	for c in _channels.values():
		if c.joined:
			joined.append(c)

	if joined.size() > 1 and not _warned_about_routing:
		_warned_about_routing = true
		PraxLog.warn(
			"This gateway sends bus messages without naming their bus, so events cannot be routed "
			+ "to the channel they came from. Every joined channel will see them. Update the "
			+ "gateway, or hold one bus per connection until you can.")

	return joined


func _drop_connection() -> void:
	if _socket != null:
		_socket.close()
		_socket = null
	_on_closed()


func _on_closed() -> void:
	for c in _channels.values():
		c.joined = false

	# Anything still waiting is answered by invoke()'s own null-socket check.
	if _closed_by_us or not auto_reconnect:
		_set_state("disconnected")
		return

	_set_state("reconnecting")
	_reconnect_delay = (reconnect_delay_seconds if _reconnect_delay <= 0.0
		else minf(_reconnect_delay * 2.0, max_reconnect_delay_seconds))
	_reconnect_at = Time.get_unix_time_from_system() + _reconnect_delay
	PraxLog.info("Event Bus reconnecting in %.1fs." % _reconnect_delay)


func _maybe_reconnect() -> void:
	if state != "reconnecting" or _reconnect_at <= 0.0:
		return
	if Time.get_unix_time_from_system() < _reconnect_at:
		return

	_reconnect_at = 0.0
	var failure: Variant = await connect_to_hub()
	if failure is PraxError:
		PraxLog.warn("Event Bus reconnect failed: " + failure.message)
		_on_closed()


## Re-joins every bus the game still wants.
##
## Not optional bookkeeping. SignalR group membership does not survive a reconnect, so a client
## that reconnects and stops there is connected and in no groups - receiving nothing, reporting no
## error, and looking for all the world like a broken server.
##
## Re-joining calls JoinBus again, which re-runs the topic's access rule. The SDK never replays a
## membership list for the server to take on faith.
func _rejoin_all() -> void:
	for c in _channels.values():
		if not c.wanted or c.joined:
			continue
		var result: Variant = await c.join()
		if result is PraxError:
			PraxLog.warn('Could not re-join "%s": %s' % [c.key, result.message])
		else:
			PraxLog.info('Re-joined "%s" after reconnecting.' % c.key)


func _set_state(new_state: String) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(new_state)
