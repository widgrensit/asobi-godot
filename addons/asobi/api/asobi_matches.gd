class_name AsobiMatches
extends RefCounted

var _client: AsobiClient

func _init(client: AsobiClient) -> void:
	_client = client

func list() -> Dictionary:
	return await _client.http.get_request(_client, "/api/v1/matches")

func get_match(match_id: String) -> Dictionary:
	return await _client.http.get_request(_client, "/api/v1/matches/%s" % match_id)
