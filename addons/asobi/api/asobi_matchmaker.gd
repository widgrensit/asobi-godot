class_name AsobiMatchmaker
extends RefCounted

var _client: AsobiClient

func _init(client: AsobiClient) -> void:
	_client = client

func add(mode: String = "default") -> Dictionary:
	return await _client.http.post_request(_client, "/api/v1/matchmaker", {"mode": mode})

func status(ticket_id: String) -> Dictionary:
	return await _client.http.get_request(_client, "/api/v1/matchmaker/%s" % ticket_id)

func cancel(ticket_id: String) -> Dictionary:
	return await _client.http.delete_request(_client, "/api/v1/matchmaker/%s" % ticket_id)
