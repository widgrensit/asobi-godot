class_name AsobiInventory
extends RefCounted

var _client: AsobiClient

func _init(client: AsobiClient) -> void:
	_client = client

func list() -> Dictionary:
	return await _client.http.get_request(_client, "/api/v1/inventory")

func consume(item_id: String, quantity: int = 1) -> Dictionary:
	return await _client.http.post_request(
		_client, "/api/v1/inventory/consume", {"item_id": item_id, "quantity": quantity})
