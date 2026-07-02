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

var _pass_count := 0
var _fail_count := 0

func _initialize() -> void:
	_run()

func _run() -> void:
	if FileAccess.file_exists(STORE_PATH):
		DirAccess.remove_absolute(STORE_PATH)

	await _test_persistence()
	_test_store_tokens()
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
