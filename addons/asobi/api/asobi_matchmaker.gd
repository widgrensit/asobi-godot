class_name AsobiMatchmaker
extends RefCounted

var _client: AsobiClient

func _init(client: AsobiClient) -> void:
	_client = client

# The controller builds its match params from `mode` and `properties` only;
# there is no party queueing on this endpoint.
func add(mode: String = "default", properties: Dictionary = {}) -> Dictionary:
	var body := {"mode": mode}
	if not properties.is_empty():
		body["properties"] = properties
	return await _client.http.post_request(_client, "/api/v1/matchmaker", body)

func status(ticket_id: String) -> Dictionary:
	return await _client.http.get_request(_client, "/api/v1/matchmaker/%s" % ticket_id)

func cancel(ticket_id: String) -> Dictionary:
	return await _client.http.delete_request(_client, "/api/v1/matchmaker/%s" % ticket_id)
