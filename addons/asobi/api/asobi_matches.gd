class_name AsobiMatches
extends RefCounted

var _client: AsobiClient

func _init(client: AsobiClient) -> void:
	_client = client

func list(mode: String = "", status: String = "", limit: int = 0) -> Dictionary:
	var query := {}
	if mode != "":
		query["mode"] = mode
	if status != "":
		query["status"] = status
	if limit > 0:
		query["limit"] = str(limit)
	return await _client.http.get_request(_client, "/api/v1/matches", query)

func get_match(match_id: String) -> Dictionary:
	return await _client.http.get_request(_client, "/api/v1/matches/%s" % match_id)
