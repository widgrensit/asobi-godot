class_name AsobiHttp
extends Node

signal request_completed(result: Dictionary)
signal request_failed(error: String, status_code: int)
signal auth_expired

func get_request(client: AsobiClient, path: String, query: Dictionary = {}) -> Dictionary:
	var url := _build_url(client.base_url, path, query)
	return await _send(client, url, HTTPClient.METHOD_GET)

func post_request(client: AsobiClient, path: String, body: Dictionary = {}) -> Dictionary:
	var url := _build_url(client.base_url, path)
	return await _send(client, url, HTTPClient.METHOD_POST, body)

func put_request(client: AsobiClient, path: String, body: Dictionary = {}) -> Dictionary:
	var url := _build_url(client.base_url, path)
	return await _send(client, url, HTTPClient.METHOD_PUT, body)

func delete_request(client: AsobiClient, path: String, body: Dictionary = {}, query: Dictionary = {}) -> Dictionary:
	var url := _build_url(client.base_url, path, query)
	return await _send(client, url, HTTPClient.METHOD_DELETE, body)

func _send(client: AsobiClient, url: String, method: int, body: Dictionary = {}, is_retry: bool = false) -> Dictionary:
	var http_request := HTTPRequest.new()
	add_child(http_request)

	var headers: PackedStringArray = ["Content-Type: application/json"]
	if client.access_token != "":
		headers.append("Authorization: Bearer %s" % client.access_token)

	var json_body := JSON.stringify(body) if not body.is_empty() else ""

	var err: int
	if json_body != "":
		err = http_request.request(url, headers, method, json_body)
	else:
		err = http_request.request(url, headers, method)

	if err != OK:
		http_request.queue_free()
		return {"error": "Request failed with code %d" % err}

	var response: Array = await http_request.request_completed
	http_request.queue_free()

	var result_code: int = response[0]
	var status_code: int = response[1]
	var _response_headers: PackedStringArray = response[2]
	var response_body: PackedByteArray = response[3]

	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"error": "Connection error"}

	var text := response_body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text) if text != "" else {}

	if status_code == 401 and not is_retry and not _is_auth_path(url):
		var refresh_resp: Dictionary = await client.auth.refresh()
		if refresh_resp.has("error"):
			auth_expired.emit()
			return {"error": "auth_expired", "status_code": status_code}
		return await _send(client, url, method, body, true)

	if status_code >= 400:
		var failure := _failure(parsed, status_code)
		push_error("Asobi HTTP error: %s" % failure["error"])
		return failure

	return parsed if parsed is Dictionary else {}

## asobi answers every failure with a shared error object,
## {"error": {"code": ..., "message": ..., "details": {...}}}. This used to read
## `parsed.get("error", ...)` straight into a String-typed variable, so against
## any current server it tried to assign a Dictionary to a String on EVERY error
## path - a 404, a rate limit, a refused password. `code` is the half to branch
## on; `error` stays the human-readable message it always was, so existing
## callers keep working. A flat legacy string body is still accepted.
func _failure(parsed: Variant, status_code: int) -> Dictionary:
	var fallback := "HTTP %d" % status_code
	if parsed is Dictionary:
		var raw: Variant = parsed.get("error", null)
		if raw is Dictionary:
			var message: Variant = raw.get("message", fallback)
			var code: Variant = raw.get("code", "")
			return {
				"error": message if message is String else fallback,
				"code": code if code is String else "",
				"details": raw.get("details", {}),
				"status_code": status_code,
			}
		if raw is String:
			return {"error": raw, "code": "", "status_code": status_code}
	return {"error": fallback, "code": "", "status_code": status_code}

func _is_auth_path(url: String) -> bool:
	return url.contains("/api/v1/auth/")

func _build_url(base_url: String, path: String, query: Dictionary = {}) -> String:
	var url := base_url + path
	if not query.is_empty():
		var parts: PackedStringArray = []
		for key: String in query:
			parts.append("%s=%s" % [key.uri_encode(), str(query[key]).uri_encode()])
		url += "?" + "&".join(parts)
	return url
