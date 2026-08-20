## Builds gateway URLs.
##
## The Praxsuite FrontDoor accepts a short form, /{workspace_id}/query, which it rewrites to the
## backend's /api/v1/gateway/{workspace_id}/query. The SDK uses the short form: it is the
## documented public shape, and going through the FrontDoor is what applies the edge rate limit.
##
## Host matters. Praxsuite runs several independent tiers and a workspace exists on exactly one -
## a workspace on another tier returns 404, not an error you can diagnose from the message.
class_name PraxRoutes
extends RefCounted

const CLOUD_HOST := "https://gateway.praxsuite.com"


## Trims trailing slashes and defaults to https.
static func normalize_base_url(base_url: String) -> String:
	if base_url.strip_edges().is_empty():
		return CLOUD_HOST
	var url := base_url.strip_edges()
	while url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	if not url.begins_with("http://") and not url.begins_with("https://"):
		url = "https://" + url
	return url


## True for a plaintext URL that is not a loopback address.
static func is_insecure_remote(base_url: String) -> bool:
	if not base_url.to_lower().begins_with("http://"):
		return false
	var host := base_url.substr(7).split("/")[0].split(":")[0].to_lower()
	return not host in ["localhost", "127.0.0.1", "::1", "0.0.0.0"]


static func workspace_base(base_url: String, workspace_id: String) -> String:
	return normalize_base_url(base_url) + "/" + workspace_id

static func query(b: String, w: String) -> String:
	return workspace_base(b, w) + "/query"

static func schema(b: String, w: String) -> String:
	return workspace_base(b, w) + "/schema"

static func auth(b: String, w: String, action: String) -> String:
	return workspace_base(b, w) + "/auth/" + action

static func endpoint(b: String, w: String, slug: String) -> String:
	return workspace_base(b, w) + "/endpoint/" + slug.uri_encode()

static func files(b: String, w: String, suffix: String = "") -> String:
	var url := workspace_base(b, w) + "/files"
	return url if suffix.is_empty() else url + "/" + suffix
