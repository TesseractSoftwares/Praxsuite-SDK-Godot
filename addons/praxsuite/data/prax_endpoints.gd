## Calls a workspace's custom gateway endpoints.
##
## An endpoint runs an automation on the server, which is where anything a player must not be
## able to influence belongs: awarding currency, validating a score, granting an item. The game
## asks for an outcome; the server decides it.
##
## [codeblock]
## var result = await Prax.endpoints.call("submit-score", {"score": score})
## if result is PraxError: return
## print(result.get("rank"))
## [/codeblock]
##
## Two things measured against a live gateway on 2026-08-24, both of which change how this is used.
##
## The endpoint does NOT authenticate its caller for you. A POST with no credential at all returns
## 200 and runs the automation. That follows from what an endpoint is - a webhook receiver, and
## Stripe or Meta cannot hold your workspace credential - but it means putting logic here makes it
## server-EXECUTED, not automatically server-authoritative. The authority comes from the endpoint
## verifying who called: a signature secret on the endpoint, or the automation checking a verified
## claim from the session token this SDK attaches.
##
## GET is not usable. `GET /{workspace}/endpoint/{id}` never reaches the automation - the gateway
## consumes it as a Meta/Instagram webhook verification handshake and answers 400 with
## `{"error":"Unsupported hub.mode. Expected 'subscribe'."}`. Confirmed to be the route rather than
## any one endpoint: a nonexistent endpoint id answers identically. There is therefore no GET
## helper here; an earlier version had one, and it could never have worked.
class_name PraxEndpoints
extends RefCounted

## A Sync endpoint holds the connection open while its automation runs. The client's 20s default
## is below every syncTimeoutSeconds value observed in practice, so endpoint calls get their own.
const DEFAULT_ENDPOINT_TIMEOUT := 100.0

var _client: Object  # PraxsuiteClient


func _init(client: Object) -> void:
	_client = client


## POSTs to an endpoint and returns the automation's response.
##
## `slug` is the endpoint's id from the workspace's API Gateway screen. It is called a slug for
## continuity with the other SDKs, but the gateway addresses endpoints by GUID.
##
## The body comes back EXACTLY as the automation returned it. Endpoint responses are not
## platform-enveloped: measured top-level keys were the automation's own, with isSuccess, data,
## message, errors and statusCode all absent. An earlier version unwrapped `.data`, which was
## harmless only while no automation returned a top-level `data` object - the first one that did
## would have had everything beside it silently discarded.
##
## Never retried automatically: an endpoint runs an automation, and running one twice is rarely
## harmless. The default timeout is generous because a Sync endpoint holds the connection while its
## automation runs - syncTimeoutSeconds values of 30, 45, 60 and 90 were all observed in one
## workspace, and the client's own 20s default is below every one of them.
func call_endpoint(slug: String, body: Variant = null,
		timeout_seconds: float = DEFAULT_ENDPOINT_TIMEOUT) -> Variant:
	if slug.strip_edges().is_empty():
		return PraxError.new("INVALID_REQUEST", "An endpoint id is required.")

	var url := PraxRoutes.endpoint(_client.base_url, _client.workspace_id, slug.strip_edges())
	return await _client.send(HTTPClient.METHOD_POST, url, body, false, timeout_seconds)
