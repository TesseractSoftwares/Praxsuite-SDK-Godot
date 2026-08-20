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
## A trusted score is not a score the client computed carefully. It is a score the client did not
## compute at all.
class_name PraxEndpoints
extends RefCounted

var _client: Object  # PraxsuiteClient


func _init(client: Object) -> void:
	_client = client


## POSTs to an endpoint and returns its response body.
##
## Not retried automatically: an endpoint runs an automation, and running one twice is rarely
## harmless. Retry deliberately if you know the endpoint is idempotent.
func call_endpoint(slug: String, body: Variant = null) -> Variant:
	if slug.strip_edges().is_empty():
		return PraxError.new("INVALID_REQUEST", "An endpoint slug is required.")

	var url := PraxRoutes.endpoint(_client.base_url, _client.workspace_id, slug.strip_edges())
	var response: Variant = await _client.send(HTTPClient.METHOD_POST, url, body, false)
	if response is PraxError:
		return response

	# An endpoint's response is whatever its automation returns, so it may or may not be
	# platform-enveloped. unwrap_envelope leaves a bare body alone.
	return PraxResult.unwrap_envelope(response)


## GETs an endpoint. Safe to retry, so transient failures are retried automatically.
func get_endpoint(slug: String) -> Variant:
	if slug.strip_edges().is_empty():
		return PraxError.new("INVALID_REQUEST", "An endpoint slug is required.")

	var url := PraxRoutes.endpoint(_client.base_url, _client.workspace_id, slug.strip_edges())
	var response: Variant = await _client.send(HTTPClient.METHOD_GET, url, null, true)
	if response is PraxError:
		return response
	return PraxResult.unwrap_envelope(response)
