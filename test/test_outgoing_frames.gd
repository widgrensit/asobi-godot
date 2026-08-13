extends SceneTree

# Outgoing-frame unit test. The dispatch test covers inbound frames; nothing
# covered what the SDK SENDS, which is how world.list shipped passing
# has_capacity as a JSON string. The backend filter validator accepts only a
# JSON boolean and rejects the whole request with
# "invalid_has_capacity_filter", so every capacity-filtered browse failed.
#
# Run with:
#   godot --headless --path . -s test/test_outgoing_frames.gd

const _AsobiRealtimeScript := preload("res://addons/asobi/asobi_realtime.gd")

var _failures := 0

class CapturingRealtime:
	extends "res://addons/asobi/asobi_realtime.gd"
	var sent: Array = []
	# Returns the cid, matching the parent: rpc_call needs it to correlate,
	# and GDScript refuses an override whose signature differs.
	func _send(type: String, payload: Dictionary) -> String:
		sent.append({"type": type, "payload": payload})
		return str(sent.size())

	# Capture fire-and-forget frames whole so a test can assert the top-level
	# `seq` sibling appears when stamped and is absent when unset.
	func _send_fire_and_forget(type: String, payload: Dictionary, seq: int = -1) -> void:
		var frame := {"type": type, "payload": payload}
		if seq >= 0:
			frame["seq"] = seq
		sent.append(frame)

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok  ", msg)
	else:
		print("  FAIL ", msg)
		_failures += 1

func _init() -> void:
	var client: Node = preload("res://addons/asobi/asobi_client.gd").new()
	var rt := CapturingRealtime.new(client)

	rt.world_list("arena", true)
	var frame: Dictionary = rt.sent[0]
	_check(frame["type"] == "world.list", "world_list sends world.list")
	_check(frame["payload"]["mode"] == "arena", "mode is passed through")
	_check(
		typeof(frame["payload"]["has_capacity"]) == TYPE_BOOL,
		"has_capacity is a JSON boolean, not a String"
	)
	_check(frame["payload"]["has_capacity"] == true, "has_capacity is true")

	rt.sent.clear()
	rt.world_list("arena", false)
	_check(
		not rt.sent[0]["payload"].has("has_capacity"),
		"has_capacity is omitted when false rather than sent as false"
	)

	rt.sent.clear()
	rt.world_list()
	_check(rt.sent[0]["payload"].is_empty(), "no filters means an empty payload")

	rt.sent.clear()
	rt.match_list("demo", true)
	var match_frame: Dictionary = rt.sent[0]
	_check(match_frame["type"] == "match.list", "match_list sends match.list")
	_check(match_frame["payload"]["mode"] == "demo", "match_list mode is passed through")
	_check(
		typeof(match_frame["payload"]["has_capacity"]) == TYPE_BOOL,
		"match_list has_capacity is a JSON boolean, not a String"
	)

	rt.sent.clear()
	rt.match_list()
	_check(rt.sent[0]["payload"].is_empty(), "match_list with no filters sends an empty payload")

	rt.sent.clear()
	rt.join_match("m-1")
	_check(not rt.sent[0]["payload"].has("ctx"), "join_match omits ctx when none is given")

	rt.sent.clear()
	rt.join_match("m-1", {"code": "AB12"})
	var join_frame: Dictionary = rt.sent[0]
	_check(join_frame["type"] == "match.join", "join_match sends match.join")
	_check(join_frame["payload"]["ctx"] == {"code": "AB12"}, "join_match forwards ctx untouched")

	rt.sent.clear()
	rt.world_join("w-1")
	_check(not rt.sent[0]["payload"].has("ctx"), "world_join omits ctx when none is given")

	rt.sent.clear()
	rt.world_join("w-1", {"code": "AB12"})
	var world_join_frame: Dictionary = rt.sent[0]
	_check(world_join_frame["type"] == "world.join", "world_join sends world.join")
	_check(world_join_frame["payload"]["ctx"] == {"code": "AB12"}, "world_join forwards ctx untouched")

	rt.sent.clear()
	rt.add_to_matchmaker("demo", {"rank": 3})
	var mm_frame: Dictionary = rt.sent[0]
	_check(mm_frame["type"] == "matchmaker.add", "add_to_matchmaker sends matchmaker.add")
	_check(
		mm_frame["payload"].keys().size() == 2,
		"matchmaker.add carries only mode and properties - the server reads nothing else"
	)
	_check(not mm_frame["payload"].has("party"), "matchmaker.add sends no party field")

	rt.sent.clear()
	rt.world_input({"dir": "left"})
	var input_frame: Dictionary = rt.sent[0]
	_check(input_frame["type"] == "world.input", "world_input sends world.input")
	_check(input_frame["payload"] == {"dir": "left"}, "world_input forwards data as payload")
	_check(not input_frame.has("seq"), "world_input omits seq when none is given")

	rt.sent.clear()
	rt.world_input({"dir": "left"}, 7)
	var seq_frame: Dictionary = rt.sent[0]
	_check(seq_frame.get("seq") == 7, "world_input stamps seq as a top-level sibling of payload")
	_check(typeof(seq_frame["seq"]) == TYPE_INT, "seq stays numeric, not stringified")
	_check(not seq_frame["payload"].has("seq"), "seq is never nested inside payload")

	rt.sent.clear()
	rt.world_input({"dir": "left"}, 0)
	_check(rt.sent[0].get("seq") == 0, "seq 0 is stamped, not treated as unset")

	if _failures > 0:
		print("FAILED: ", _failures)
		quit(1)
	else:
		print("all outgoing-frame checks passed")
		quit(0)
