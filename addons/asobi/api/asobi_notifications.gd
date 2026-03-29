class_name AsobiNotifications
extends RefCounted

var _client: AsobiClient

func _init(client: AsobiClient) -> void:
	_client = client

func list() -> Dictionary:
	return await _client.http.get_request(_client, "/api/v1/notifications")

func mark_read(notification_id: String) -> Dictionary:
	return await _client.http.put_request(
		_client, "/api/v1/notifications/%s/read" % notification_id)

func delete_notification(notification_id: String) -> Dictionary:
	return await _client.http.delete_request(
		_client, "/api/v1/notifications/%s" % notification_id)
