extends SceneTree

# Auth unit test: exercises the access_token/refresh_token migration without
# a backend. Covers token persistence via user://, the is_authenticated
# getter, auth token storage, and the realtime session-revoked trigger.
#
# Run with:
#   godot --headless --path . -s test/test_auth.gd

const _AsobiClientScript := preload("res://addons/asobi/asobi_client.gd")
const _AsobiRealtimeScript := preload("res://addons/asobi/asobi_realtime.gd")

const STORE_PATH := "user://asobi_auth.cfg"


class StubHttp:
	extends "res://addons/asobi/asobi_http.gd"

	var last_path := ""
	var last_body := {}
	var response := {}

	func post_request(_client, path: String, body: Dictionary = {}) -> Dictionary:
		last_path = path
		last_body = body
		return response

var _pass_count := 0
var _fail_count := 0

func _initialize() -> void:
	_run()

func _run() -> void:
	if FileAccess.file_exists(STORE_PATH):
		DirAccess.remove_absolute(STORE_PATH)

	await _test_persistence()
	_test_store_tokens()
	await _test_guest()
	await _test_upgrade_guest()
	_test_realtime_revoke()

	print("[auth] %d passed, %d failed" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)

func _test_persistence() -> void:
	var writer: Node = _AsobiClientScript.new()
	root.add_child(writer)
	await process_frame
	writer.access_token = "acc-1"
	writer.refresh_token = "ref-1"
	writer.save_refresh_token()
	writer.queue_free()
	await process_frame

	var reader: Node = _AsobiClientScript.new()
	root.add_child(reader)
	await process_frame
	_check(reader.refresh_token == "ref-1", "refresh_token persisted and reloaded on init")
	_check(not reader.is_authenticated, "not authenticated without access_token")
	reader.access_token = "acc-2"
	_check(reader.is_authenticated, "authenticated once access_token is set")

	reader.clear_persisted_token()
	_check(reader.refresh_token == "", "clear_persisted_token wipes refresh_token")
	_check(not FileAccess.file_exists(STORE_PATH), "clear_persisted_token removes the store file")
	reader.queue_free()
	await process_frame

	var fresh: Node = _AsobiClientScript.new()
	root.add_child(fresh)
	await process_frame
	_check(fresh.refresh_token == "", "cleared token is not reloaded")
	fresh.queue_free()

func _test_store_tokens() -> void:
	var client: Node = _AsobiClientScript.new()
	root.add_child(client)
	client.auth._store_tokens({
		"access_token": "a",
		"refresh_token": "r",
		"player_id": "p"
	})
	_check(client.access_token == "a", "_store_tokens sets access_token")
	_check(client.refresh_token == "r", "_store_tokens sets refresh_token")
	_check(client.player_id == "p", "_store_tokens sets player_id")
	client.clear_persisted_token()
	client.queue_free()

func _test_guest() -> void:
	var client: Node = _AsobiClientScript.new()
	root.add_child(client)
	await process_frame
	var stub := StubHttp.new()
	client.http = stub

	stub.response = {
		"player_id": "guest-1",
		"access_token": "ga",
		"refresh_token": "gr",
		"username": "guest_abc",
		"created": true,
		"guest": true
	}
	var resp: Dictionary = await client.auth.guest("device-1", "c2VjcmV0")
	var expected_body := {"device_id": "device-1", "device_secret": "c2VjcmV0"}
	_check(stub.last_path == "/api/v1/auth/guest", "guest posts to /api/v1/auth/guest")
	_check(stub.last_body == expected_body, "guest sends device_id + device_secret")
	_check(client.access_token == "ga", "guest stores access_token")
	_check(client.refresh_token == "gr", "guest stores refresh_token")
	_check(client.player_id == "guest-1", "guest stores player_id")
	_check(resp.get("created") == true, "guest returns the raw response dictionary")

	stub.response = {"error": "guest_auth_disabled", "status_code": 403}
	var err: Dictionary = await client.auth.guest("device-1", "c2VjcmV0")
	_check(err.has("error"), "guest surfaces backend error")
	_check(client.access_token == "ga", "guest does not overwrite tokens on error")

	client.clear_persisted_token()
	stub.free()
	client.queue_free()

func _test_upgrade_guest() -> void:
	var client: Node = _AsobiClientScript.new()
	root.add_child(client)
	await process_frame
	var stub := StubHttp.new()
	client.http = stub
	client.access_token = "ga"
	client.refresh_token = "gr"
	client.player_id = "guest-1"

	stub.response = {
		"player_id": "guest-1",
		"access_token": "ua",
		"refresh_token": "ur",
		"username": "claimed",
		"upgraded": true
	}
	var resp: Dictionary = await client.auth.upgrade_guest("claimed", "secret123")
	_check(stub.last_path == "/api/v1/auth/guest/upgrade", "upgrade_guest posts to /api/v1/auth/guest/upgrade")
	_check(stub.last_body == {"username": "claimed", "password": "secret123"}, "upgrade_guest sends username + password")
	_check(client.access_token == "ua", "upgrade_guest replaces access_token")
	_check(client.refresh_token == "ur", "upgrade_guest replaces refresh_token")
	_check(resp.get("upgraded") == true, "upgrade_guest returns the raw response dictionary")

	stub.response = {"error": "username_taken", "status_code": 409}
	var err: Dictionary = await client.auth.upgrade_guest("claimed", "secret123")
	_check(err.has("error"), "upgrade_guest surfaces backend error")
	_check(client.access_token == "ua", "upgrade_guest keeps tokens on error")

	client.clear_persisted_token()
	stub.free()
	client.queue_free()

func _test_realtime_revoke() -> void:
	var revoked: Node = _AsobiRealtimeScript.new(null)
	root.add_child(revoked)
	var fired := [false]
	revoked.session_revoked.connect(func() -> void: fired[0] = true)
	revoked._handle_message('{"type":"error","payload":{"reason":"invalid_token"}}')
	_check(fired[0], "session_revoked fires on invalid_token error")
	revoked.reauthenticate()
	_check(not revoked._is_connecting, "revoked session does not reconnect with a dead token")
	revoked.queue_free()

	var benign: Node = _AsobiRealtimeScript.new(null)
	root.add_child(benign)
	benign._handle_message('{"type":"error","payload":{"reason":"invalid_message"}}')
	_check(not benign._revoked, "benign error does not revoke the session")
	benign.queue_free()

func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass_count += 1
		print("[auth] PASS: ", msg)
	else:
		_fail_count += 1
		printerr("[auth] FAIL: ", msg)
