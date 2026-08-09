class_name AsobiPlayers
extends RefCounted

var _client: AsobiClient

func _init(client: AsobiClient) -> void:
	_client = client

func get_player(player_id: String) -> Dictionary:
	return await _client.http.get_request(_client, "/api/v1/players/%s" % player_id)

func update(
	player_id: String, display_name: String = "",
	avatar_url: String = "", metadata: Dictionary = {}
) -> Dictionary:
	var body := {}
	if display_name != "":
		body["display_name"] = display_name
	if avatar_url != "":
		body["avatar_url"] = avatar_url
	if not metadata.is_empty():
		body["metadata"] = metadata
	return await _client.http.put_request(_client, "/api/v1/players/%s" % player_id, body)

func get_self() -> Dictionary:
	return await get_player(_client.player_id)

## Erases the signed-in account and everything the server holds for it - saves,
## storage, inventory, wallets, leaderboard entries, identities. Irreversible.
##
## Pass [param password] only for an account that has one. A guest or a
## provider-only account has no credential the client can re-present, so its
## session is the whole confirmation.
##
## Clears the local session on success only, deliberately unlike [method
## AsobiAuth.logout], which clears regardless: a refused confirmation (403
## player.confirmation_failed) or a credential change mid-flight (409) leaves a
## live account whose session must survive. On success the server deleted the
## token pair inside the erase transaction, so keeping it would only buy a
## doomed refresh on the next call.
##
## Needs a server carrying POST /api/v1/players/me/erase; older ones 404.
func erase_self(password: String = "") -> Dictionary:
	var body := {}
	if password != "":
		body["password"] = password
	var resp := await _client.http.post_request(_client, "/api/v1/players/me/erase", body)
	if not resp.has("error"):
		_client.access_token = ""
		_client.player_id = ""
		_client.clear_persisted_token()
	return resp
