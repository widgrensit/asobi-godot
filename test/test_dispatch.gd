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
	"game.message": "game_message",
	"module.error": "game_error",
	"module.message": "game_message",
	"module.event": "module_event",
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
	"world.ack": "world_ack",
}

# rpc.ok and rpc.error are replies, not events: they correlate to one call by
# `cid` and never reach the dispatch table. They have fixtures, so they are
# named here rather than left looking like an oversight; test_rpc.gd covers
# the correlation.
const CORRELATED := ["rpc.ok", "rpc.error"]

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
		if CORRELATED.has(mtype):
			continue
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
	_run_game_message_string_value()
	_run_game_message_non_string_value()
	_run_game_message_null_value()
	_run_module_event_payload()
	_run_module_event_unknown_event()
	_run_world_ack_number_typing()

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

# game_message must carry the whole payload Dictionary, with the fixture's
# string value intact under the "message" key.
func _run_game_message_string_value() -> void:
	var raw := _read_file("%s/game.message.json" % FIXTURE_DIR)
	if raw == "":
		_fail("could not read game.message.json")
		return

	var realtime: Node = _AsobiRealtimeScript.new(null)
	root.add_child(realtime)
	var fired := [false]
	var got := [null]
	var on_signal := func(payload: Dictionary) -> void:
		fired[0] = true
		got[0] = payload
	realtime.connect("game_message", on_signal)
	realtime._handle_message(raw)
	realtime.queue_free()

	if not fired[0]:
		_fail("game.message did not fire the signal")
	elif got[0].get("message") == "jij bent speler nummer 3":
		_pass("game.message -> game_message carries the fixture string")
	else:
		_fail("game.message string value mismatch: %s" % [got[0]])

# game.send/2 accepts any Lua value - a number or a table - not just a
# string. game_message's payload is typed Dictionary and its "message" field
# is untyped Variant specifically to preserve that, unlike game_error's
# message field which is display-only and coerced to String via _as_text.
# Prove a non-string value round-trips as-is rather than crashing or getting
# silently stringified.
func _run_game_message_non_string_value() -> void:
	var raw := JSON.stringify({
		"type": "game.message",
		"payload": {"message": {"hp": 3, "items": ["sword", "shield"]}}
	})

	var realtime: Node = _AsobiRealtimeScript.new(null)
	root.add_child(realtime)
	var fired := [false]
	var got := [null]
	var on_signal := func(payload: Dictionary) -> void:
		fired[0] = true
		got[0] = payload
	realtime.connect("game_message", on_signal)
	realtime._handle_message(raw)
	realtime.queue_free()

	# JSON numbers parse as float in GDScript (see the game.error malformed
	# test above), so hp round-trips as 3.0.
	var expected := {"hp": 3.0, "items": ["sword", "shield"]}
	if not fired[0]:
		_fail("game.message with a non-string value did not fire the signal")
	elif got[0].get("message") != expected:
		_fail("game.message non-string value mismatch: %s" % [got[0]])
	else:
		_pass("game.message preserves a non-string (table) value")

# A payload whose "message" key is explicitly null, or missing entirely,
# must still fire the signal rather than crashing or silently dropping the
# event - the same class of case _run_game_error_malformed_payload covers
# for game.error.
func _run_game_message_null_value() -> void:
	var raw := JSON.stringify({
		"type": "game.message",
		"payload": {"message": null}
	})

	var realtime: Node = _AsobiRealtimeScript.new(null)
	root.add_child(realtime)
	var fired := [false]
	var got := [null]
	var on_signal := func(payload: Dictionary) -> void:
		fired[0] = true
		got[0] = payload
	realtime.connect("game_message", on_signal)
	realtime._handle_message(raw)
	realtime.queue_free()

	if not fired[0]:
		_fail("game.message with a null message value did not fire the signal")
	elif got[0].get("message") != null:
		_fail("game.message null value mismatch: %s" % [got[0]])
	else:
		_pass("game.message tolerates a null message value without crashing")

# module_event surfaces the whole payload of a named extension push, with
# module (which extension), event (the event name), and data (its body) all
# intact under their keys.
func _run_module_event_payload() -> void:
	var raw := _read_file("%s/module.event.json" % FIXTURE_DIR)
	if raw == "":
		_fail("could not read module.event.json")
		return

	var realtime: Node = _AsobiRealtimeScript.new(null)
	root.add_child(realtime)
	var fired := [false]
	var got := [null]
	var on_signal := func(payload: Dictionary) -> void:
		fired[0] = true
		got[0] = payload
	realtime.connect("module_event", on_signal)
	realtime._handle_message(raw)
	realtime.queue_free()

	if not fired[0]:
		_fail("module.event did not fire the signal")
	elif got[0].get("module") != "quests" or got[0].get("event") != "quests.completed":
		_fail("module.event module/event mismatch: %s" % [got[0]])
	elif got[0].get("data", {}).get("quest_id") != "01j8x000000000000000000042":
		_fail("module.event data payload mismatch: %s" % [got[0]])
	else:
		_pass("module.event -> module_event carries module, event, and data")

# The inner `event` name is data the app routes on, not a dispatch gate: an
# unfamiliar name still surfaces via module_event rather than being dropped.
# This is the conformance behaviour the 1.0 wire freeze needs.
func _run_module_event_unknown_event() -> void:
	var raw := JSON.stringify({
		"type": "module.event",
		"payload": {"module": "quests", "event": "mystery.happened", "data": {"n": 1}}
	})

	var realtime: Node = _AsobiRealtimeScript.new(null)
	root.add_child(realtime)
	var fired := [false]
	var got := [null]
	var on_signal := func(payload: Dictionary) -> void:
		fired[0] = true
		got[0] = payload
	realtime.connect("module_event", on_signal)
	realtime._handle_message(raw)
	realtime.queue_free()

	if not fired[0]:
		_fail("module.event with an unfamiliar inner event was dropped instead of surfaced")
	elif got[0].get("event") != "mystery.happened":
		_fail("module.event unknown-event value mismatch: %s" % [got[0]])
	else:
		_pass("module.event surfaces an unfamiliar inner event name")

# The wire carries tick and seq as JSON integers, but JSON.parse_string decodes
# every number as a float, so a handler receives 42.0 / 412.0 rather than ints.
# The README documents that and casts with int(); this pins the behaviour so the
# documented cast cannot quietly become wrong advice.
func _run_world_ack_number_typing() -> void:
	var raw := _read_file("%s/world.ack.json" % FIXTURE_DIR)
	if raw == "":
		_fail("could not read world.ack.json")
		return

	var realtime: Node = _AsobiRealtimeScript.new(null)
	root.add_child(realtime)
	var got := [null]
	var on_signal := func(payload: Dictionary) -> void: got[0] = payload
	realtime.connect("world_ack", on_signal)
	realtime._handle_message(raw)
	realtime.queue_free()

	if got[0] == null:
		_fail("world.ack did not fire world_ack")
	elif typeof(got[0]["tick"]) != TYPE_FLOAT or typeof(got[0]["seq"]) != TYPE_FLOAT:
		_fail("world.ack numbers are no longer floats: %s" % [got[0]])
	elif int(got[0]["tick"]) != 42 or int(got[0]["seq"]) != 412:
		_fail("world.ack values mismatch after int() cast: %s" % [got[0]])
	else:
		_pass("world.ack tick/seq arrive as floats and int() recovers the values")

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
