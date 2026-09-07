## The Event Bus wire format: SignalR's JSON hub protocol, version 1.
##
## Everything here is pure and synchronous so it can be tested with no socket, which is how the
## conformance cases in cases/event-bus.json are run.
##
## The protocol is spoken directly. There is no SignalR client for Godot, this SDK has no
## dependencies, and the surface used here is four message types wide.
class_name PraxBusWire
extends RefCounted

## ASCII record separator. SignalR terminates every frame with it.
const RS := "\u001e"

## The handshake, byte for byte. SignalR compares it literally - a trailing newline or a space
## after a colon fails it, with an error that does not say so.
const HANDSHAKE_FRAME := '{"protocol":"json","version":1}'

## The hub's path. There is no workspace segment: the workspace comes from the token.
const BUS_PATH := "/hubs/event-bus"

const MSG_INVOCATION := 1
const MSG_COMPLETION := 3
const MSG_PING := 6
const MSG_CLOSE := 7


## Splits a received buffer into whole frames.
##
## Returns { "frames": PackedStringArray, "remainder": String }.
##
## Two things go wrong without this. A single physical message can carry SEVERAL frames, so
## parsing the whole buffer as JSON fails exactly when traffic picks up - the load the bus exists
## for. And a transport may split one frame across two reads, so the tail is kept rather than
## parsed or discarded.
static func split_frames(buffer: String) -> Dictionary:
	var frames := PackedStringArray()
	if buffer.is_empty():
		return {"frames": frames, "remainder": ""}

	var parts := buffer.split(RS)
	for i in range(parts.size() - 1):
		if not parts[i].is_empty():
			frames.append(parts[i])

	return {"frames": frames, "remainder": parts[parts.size() - 1]}


## Wraps a frame for sending.
static func frame(payload: String) -> String:
	return payload + RS


## Folds a bus key the way the server does: the TOPIC segment to lowercase, the instance untouched.
##
## BusAddress.ForCaller folds the topic both when it resolves the topic and when it builds the
## SignalR group name, so "Office:hq" and "office:hq" are one bus. Folding the whole key instead
## would merge "office:HQ" and "office:hq", which are two genuinely different buses. Fold the same
## half the server folds and neither mistake is possible.
static func normalize_bus_key(bus_key: String) -> String:
	var key := bus_key.strip_edges()
	if key.is_empty():
		return ""

	var separator := key.find(":")
	if separator <= 0:
		return key.to_lower()

	return key.substr(0, separator).to_lower() + key.substr(separator)


## Rejects keys the server would reject anyway, without spending a round trip on it.
## Returns a PraxError, or null when the key is usable.
static func check_bus_key(bus_key: String) -> PraxError:
	var key := normalize_bus_key(bus_key)

	if key.is_empty():
		return PraxError.new("INVALID_BUS_KEY",
			'A bus key is required. It looks like "topic:instance", e.g. "office:hq".')

	# The group name is built by concatenation, so a key carrying the separator could climb out of
	# its own segment and name another workspace's group.
	if key.contains("ws:"):
		return PraxError.new("INVALID_BUS_KEY",
			'A bus key may not contain "ws:" (got "%s"). The server refuses it.' % bus_key)

	if key.length() > 200:
		return PraxError.new("INVALID_BUS_KEY",
			"Bus key is too long (%d characters)." % key.length())

	return null


## Builds an invocation frame. invocation_id is a STRING - SignalR matches completions on it by
## value, and a numeric id never matches.
static func build_invocation(invocation_id: String, target: String, args: Array) -> String:
	return JSON.stringify({
		"type": MSG_INVOCATION,
		"invocationId": invocation_id,
		"target": target,
		"arguments": args,
	})


## Reads a completion frame into { ok, error, peers, recipients, is_transport_error }.
##
## The trap this exists for: the hub answers a REJECTED call with a SUCCESSFUL completion whose
## result carries ok:false. Code that only inspects SignalR's error field reports every denied
## join as a success. And LeaveBus is void, so its result is literally null.
static func parse_bus_result(message: Dictionary) -> Dictionary:
	var parsed := {
		"ok": true,
		"error": "",
		"peers": [],
		"recipients": 0,
		"is_transport_error": false,
	}

	var transport_error := str(message.get("error", ""))
	if not transport_error.is_empty():
		parsed["ok"] = false
		parsed["error"] = transport_error
		parsed["is_transport_error"] = true
		return parsed

	var body: Variant = message.get("result")
	if not (body is Dictionary):
		return parsed  # void, e.g. LeaveBus

	var result: Dictionary = body
	parsed["ok"] = result.get("ok", true) != false
	parsed["error"] = str(result.get("error", "")) if result.get("error") != null else ""

	# Godot's JSON parser returns every number as a float, so a recipient count arrives as 1.0.
	parsed["recipients"] = int(result.get("recipients", 0))

	var peers: Variant = result.get("peers")
	if peers is Array:
		var states := []
		for entry in peers:
			if entry is Dictionary:
				states.append({
					"user_id": str(entry.get("userId", "")),
					"event": str(entry.get("event", "")),
					"payload": entry.get("payload"),
				})
		parsed["peers"] = states

	return parsed


## Negotiate: a zero-length POST with the end-user JWT as a bearer token.
static func negotiate_url(base_url: String) -> String:
	return PraxRoutes.normalize_base_url(base_url) + BUS_PATH + "/negotiate?negotiateVersion=1"


## The WebSocket URL, with the session token in the query string.
##
## The token goes in the query because the hub accepts access_token for exactly that reason - a
## browser WebSocket cannot set headers, and keeping one placement across every runtime is what
## makes this transport identical in an exported game and in a web build.
static func socket_url(base_url: String, access_token: String) -> String:
	var http := PraxRoutes.normalize_base_url(base_url)
	var ws := http
	if http.begins_with("https://"):
		ws = "wss://" + http.substr(8)
	elif http.begins_with("http://"):
		ws = "ws://" + http.substr(7)

	return ws + BUS_PATH + "?access_token=" + access_token.uri_encode()


## Turns a hub error code into a sentence worth reading. The codes are stable and are what callers
## should branch on; these strings are not.
static func describe_error(code: String) -> String:
	match code:
		"unknown_topic":
			return ("That topic is not declared in this workspace. Buses are never auto-created - "
				+ "declare the topic under API Gateway / Event Bus first.")
		"denied":
			return ("The topic refused this user. Check its access mode: Workspace, Roles (read "
				+ "straight from the JWT), or Grants (which needs a grant on this exact bus instance).")
		"invalid_ticket":
			return "The ticket was missing, expired, or minted for a different user, workspace or bus."
		"not_a_member":
			return ("Publish to a bus this connection has not joined. Join it first - membership is "
				+ "the authorization check on the publish path.")
		"invalid_bus_key":
			return ('The key is malformed, or it named another user\'s "user:" bus. Only "user:self" '
				+ "is addressable.")
		"invalid_event_name":
			return "The event name was empty or too long."
		"payload_too_large":
			return "The payload is over this topic's byte limit."
		"bus_full_or_too_many_buses":
			return "The bus is at its peer limit, or this connection already holds as many buses as it may."
		"rate_limited":
			return ("Too many publishes. The limit is priced by RECIPIENTS, so a large bus exhausts "
				+ "it faster than a small one.")
		_:
			return code if not code.is_empty() else "The bus refused the call."
