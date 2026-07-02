extends SceneTree

# Players unit test: verifies AsobiPlayers.update builds the PUT body from the
# optional display_name / avatar_url / metadata arguments. No network — the
# HTTP layer is stubbed to capture the outgoing body.
#
# Run with:
#   godot --headless --path . -s test/test_players.gd

const _AsobiClientScript := preload("res://addons/asobi/asobi_client.gd")

class CaptureHttp extends AsobiHttp:
	var last_path: String = ""
	var last_body: Dictionary = {}

	func put_request(_client: AsobiClient, path: String, body: Dictionary = {}) -> Dictionary:
		last_path = path
		last_body = body
		return {"ok": true}

var _pass_count := 0
var _fail_count := 0

func _initialize() -> void:
	_run()

func _run() -> void:
	var client: Node = _AsobiClientScript.new()
	root.add_child(client)
	await process_frame

	var capture := CaptureHttp.new()
	client.add_child(capture)
	client.http = capture

	await client.players.update("p1", "Neo")
	_check(capture.last_path == "/api/v1/players/p1", "update targets the player path")
	_check(capture.last_body == {"display_name": "Neo"}, "display_name only")

	await client.players.update("p1", "", "https://cdn/a.png")
	_check(capture.last_body == {"avatar_url": "https://cdn/a.png"}, "avatar_url only")

	await client.players.update("p1", "", "", {"level": 7, "clan": "red"})
	_check(capture.last_body == {"metadata": {"level": 7, "clan": "red"}}, "metadata only")

	await client.players.update("p1", "Neo", "https://cdn/a.png", {"level": 7})
	_check(
		capture.last_body == {
			"display_name": "Neo",
			"avatar_url": "https://cdn/a.png",
			"metadata": {"level": 7}
		},
		"all three fields"
	)

	await client.players.update("p1", "", "", {})
	_check(capture.last_body == {}, "empty metadata is omitted")

	await client.players.update("p1")
	_check(capture.last_body == {}, "no fields yields an empty body")

	client.queue_free()

	print("[players] %d passed, %d failed" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)

func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass_count += 1
		print("[players] PASS: ", msg)
	else:
		_fail_count += 1
		printerr("[players] FAIL: ", msg)
