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
	func _send(type: String, payload: Dictionary) -> void:
		sent.append({"type": type, "payload": payload})

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

	if _failures > 0:
		print("FAILED: ", _failures)
		quit(1)
	else:
		print("all outgoing-frame checks passed")
		quit(0)
