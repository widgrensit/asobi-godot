extends SceneTree

# Dispatch unit test: feeds every canonical fixture through AsobiRealtime's
# message handler and asserts the right signal fires.
#
# Pure unit test — no network, no backend. Catches doc-vs-server drift
# before any user reports a silent failure. The vote lifecycle
# (match.vote_start/tally/result/vetoed) has dedicated signals; the long tail of
# undocumented match.*/world.* events reaches games via the generic
# match_event/world_event passthrough rather than an invented named signal.
#
# Run with:
#   godot --headless --path . -s test/test_dispatch.gd

const _AsobiRealtimeScript := preload("res://addons/asobi/asobi_realtime.gd")

const FIXTURE_DIR := "res://test/fixtures"

# For each server wire `type`, the AsobiRealtime signal a user binds.
# Mirrors the dispatch table in addons/asobi/asobi_realtime.gd. Drift
# between this map and the SDK is caught by the assertions below.
const EXPECTED := {
	"error": "error_received",
	"game.error": "game_error",
	"session.connected": "connected",
	"session.heartbeat": "heartbeat",
	"match.state": "match_state",
	"match.matched": "match_matched",
	"match.joined": "match_joined",
	"match.left": "match_left",
	"match.finished": "match_finished",
	"match.list": "match_list_received",
	"match.matchmaker_expired": "matchmaker_expired",
	"match.matchmaker_failed": "matchmaker_failed",
	"match.vote_start": "vote_start",
	"match.vote_tally": "vote_tally",
	"match.vote_result": "vote_result",
	"match.vote_vetoed": "vote_vetoed",
	"matchmaker.queued": "matchmaker_queued",
	"matchmaker.removed": "matchmaker_removed",
	"chat.joined": "chat_joined",
	"chat.left": "chat_left",
	"chat.message": "chat_message",
	"dm.sent": "dm_sent",
	"dm.message": "dm_message",
	"presence.updated": "presence_updated",
	"notification.new": "notification_received",
	"vote.cast_ok": "vote_cast_ok",
	"vote.veto_ok": "vote_veto_ok",
	"world.tick": "world_tick",
	"world.terrain": "world_terrain",
	"world.list": "world_list_received",
	"world.joined": "world_joined",
	"world.left": "world_left",
	"world.phase_changed": "world_phase_changed",
	"world.finished": "world_finished",
}

var _pass_count := 0
var _fail_count := 0

func _initialize() -> void:
	_run()
	if _fail_count > 0:
		quit(1)
	else:
		quit(0)

func _run() -> void:
	var fixtures := _list_fixtures()
	if fixtures.is_empty():
		_fail("no fixtures found in %s" % FIXTURE_DIR)
		return

	var fixture_types := {}
	for name in fixtures:
		fixture_types[_strip_json(name)] = true

	# Every fixture must have an EXPECTED entry.
	for name in fixtures:
		var mtype := _strip_json(name)
		if not EXPECTED.has(mtype):
			_fail("fixture '%s' has no entry in EXPECTED — add a SDK signal mapping" % name)

	# Every EXPECTED entry must have a fixture.
	for mtype in EXPECTED.keys():
		if not fixture_types.has(mtype):
			_fail("EXPECTED maps '%s' but no fixture exists — stale or fixture missing" % mtype)

	for name in fixtures:
		var mtype := _strip_json(name)
		if not EXPECTED.has(mtype):
			continue
		var expected_signal: String = EXPECTED[mtype]
		var raw := _read_file("%s/%s" % [FIXTURE_DIR, name])
		if raw == "":
			_fail("could not read %s" % name)
			continue

		var realtime: Node = _AsobiRealtimeScript.new(null)
		root.add_child(realtime)
		var fired := [false]
		var on_signal := func(_a = null, _b = null, _c = null) -> void: fired[0] = true
		realtime.connect(expected_signal, on_signal)
		realtime._handle_message(raw)
		if fired[0]:
			_pass("%s -> %s" % [mtype, expected_signal])
		else:
			_fail("%s did not fire signal '%s'" % [mtype, expected_signal])
		realtime.queue_free()

	_run_game_error_fields()
	_run_game_error_malformed_payload()

	print("[dispatch] %d passed, %d failed (%d fixtures)" % [_pass_count, _fail_count, fixtures.size()])

# game_error carries three positional fields (not a single payload Dictionary
# like most signals); assert the fixture's exact values land in order.
func _run_game_error_fields() -> void:
	var raw := _read_file("%s/game.error.json" % FIXTURE_DIR)
	if raw == "":
		_fail("could not read game.error.json")
		return

	var realtime: Node = _AsobiRealtimeScript.new(null)
	root.add_child(realtime)
	var got := {"callback": "", "script": "", "message": ""}
	var on_signal := func(callback: String, script: String, message: String) -> void:
		got["callback"] = callback
		got["script"] = script
		got["message"] = message
	realtime.connect("game_error", on_signal)
	realtime._handle_message(raw)
	realtime.queue_free()

	var expected := {"callback": "handle_input", "script": "match.lua", "message": "bad arithmetic + on nil, 1"}
	if got == expected:
		_pass("game.error -> game_error fields match fixture")
	else:
		_fail("game.error fields mismatch: %s" % [got])

# A present-but-null or non-string field must not crash signal delivery.
# Dictionary.get(key, default) only substitutes the default when the key
# is absent - a typed signal emit given a raw null/int argument raises
# "Cannot convert argument from Nil/int to String" and the handler never
# runs, which is the worst failure mode for a diagnostic-surfacing event.
func _run_game_error_malformed_payload() -> void:
	var raw := JSON.stringify({
		"type": "game.error",
		"payload": {"callback": "handle_input", "script": null, "message": 42}
	})

	var realtime: Node = _AsobiRealtimeScript.new(null)
	root.add_child(realtime)
	var fired := [false]
	var got := {"callback": "", "script": "", "message": ""}
	var on_signal := func(callback: String, script: String, message: String) -> void:
		fired[0] = true
		got["callback"] = callback
		got["script"] = script
		got["message"] = message
	realtime.connect("game_error", on_signal)
	realtime._handle_message(raw)
	realtime.queue_free()

	# JSON numbers parse as float in GDScript, so 42 round-trips as "42.0" -
	# the point of this test is "it doesn't crash and coerces to a string",
	# not a specific numeric format.
	if not fired[0]:
		_fail("game.error with a null/non-string field did not fire the signal")
	elif got["script"] != "" or got["message"] != "42.0":
		_fail("game.error malformed-field coercion mismatch: %s" % [got])
	else:
		_pass("game.error tolerates a null/non-string field without crashing")

func _list_fixtures() -> Array:
	var out: Array = []
	var dir := DirAccess.open(FIXTURE_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	while true:
		var n := dir.get_next()
		if n == "":
			break
		if dir.current_is_dir():
			continue
		if n.ends_with(".json"):
			out.append(n)
	dir.list_dir_end()
	out.sort()
	return out

func _strip_json(name: String) -> String:
	if name.ends_with(".json"):
		return name.substr(0, name.length() - 5)
	return name

func _read_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s

func _pass(msg: String) -> void:
	_pass_count += 1
	print("[dispatch] PASS: ", msg)

func _fail(msg: String) -> void:
	_fail_count += 1
	printerr("[dispatch] FAIL: ", msg)
