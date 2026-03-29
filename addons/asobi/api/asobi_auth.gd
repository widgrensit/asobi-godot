class_name AsobiAuth
extends RefCounted

var _client: AsobiClient

func _init(client: AsobiClient) -> void:
	_client = client

func register(username: String, password: String, display_name: String = "") -> Dictionary:
	var body := {
		"username": username,
		"password": password,
		"display_name": display_name if display_name != "" else username
	}
	var resp: Dictionary = await _client.http.post_request(_client, "/api/v1/auth/register", body)
	if not resp.has("error"):
		_client.session_token = resp.get("session_token", "")
		_client.player_id = resp.get("player_id", "")
	return resp

func login(username: String, password: String) -> Dictionary:
	var body := {"username": username, "password": password}
	var resp: Dictionary = await _client.http.post_request(_client, "/api/v1/auth/login", body)
	if not resp.has("error"):
		_client.session_token = resp.get("session_token", "")
		_client.player_id = resp.get("player_id", "")
	return resp

func refresh() -> Dictionary:
	var body := {"session_token": _client.session_token}
	var resp: Dictionary = await _client.http.post_request(_client, "/api/v1/auth/refresh", body)
	if not resp.has("error"):
		_client.session_token = resp.get("session_token", "")
	return resp

func logout() -> void:
	_client.session_token = ""
	_client.player_id = ""
