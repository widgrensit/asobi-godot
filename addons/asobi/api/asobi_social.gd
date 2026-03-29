class_name AsobiSocial
extends RefCounted

var _client: AsobiClient

func _init(client: AsobiClient) -> void:
	_client = client

func get_friends(status: String = "", limit: int = 50) -> Dictionary:
	var query := {"limit": str(limit)}
	if status != "":
		query["status"] = status
	return await _client.http.get_request(_client, "/api/v1/friends", query)

func add_friend(friend_id: String) -> Dictionary:
	return await _client.http.post_request(_client, "/api/v1/friends", {"friend_id": friend_id})

func accept_friend(friend_id: String) -> Dictionary:
	return await _client.http.put_request(
		_client, "/api/v1/friends/%s" % friend_id, {"status": "accepted"})

func block_friend(friend_id: String) -> Dictionary:
	return await _client.http.put_request(
		_client, "/api/v1/friends/%s" % friend_id, {"status": "blocked"})

func remove_friend(friend_id: String) -> Dictionary:
	return await _client.http.delete_request(_client, "/api/v1/friends/%s" % friend_id)

func create_group(group_name: String, description: String = "", max_members: int = 50, open: bool = false) -> Dictionary:
	return await _client.http.post_request(_client, "/api/v1/groups", {
		"name": group_name, "description": description,
		"max_members": max_members, "open": open})

func get_group(group_id: String) -> Dictionary:
	return await _client.http.get_request(_client, "/api/v1/groups/%s" % group_id)

func join_group(group_id: String) -> Dictionary:
	return await _client.http.post_request(_client, "/api/v1/groups/%s/join" % group_id)

func leave_group(group_id: String) -> Dictionary:
	return await _client.http.post_request(_client, "/api/v1/groups/%s/leave" % group_id)

func get_chat_history(channel_id: String) -> Dictionary:
	return await _client.http.get_request(_client, "/api/v1/chat/%s/history" % channel_id)
