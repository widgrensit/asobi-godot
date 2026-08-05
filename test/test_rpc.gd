extends SceneTree

# The RPC seam: an extension's method, called over the same socket and
# correlated by cid. Pure unit test — no network, no backend.
#
# Reply correlation was declared and never built here: `_pending` existed, a
# cid was minted for every send, and `_handle_message` read neither. These
# assertions are the difference.
#
# Run with:
#   godot --headless --path . -s test/test_rpc.gd

const _AsobiRealtimeScript := preload("res://addons/asobi/asobi_realtime.gd")

const FIXTURE_DIR := "res://test/fixtures"

var _pass_count := 0
var _fail_count := 0

func _initialize() -> void:
	_run()
	if _fail_count > 0:
		quit(1)
	else:
		quit(0)

func _pass(what: String) -> void:
	_pass_count += 1
	print("[rpc] PASS: %s" % what)

func _fail(what: String) -> void:
	_fail_count += 1
	printerr("[rpc] FAIL: %s" % what)

func _check(what: String, got: Variant, want: Variant) -> void:
	if got == want:
		_pass(what)
	else:
		_fail("%s — got %s, want %s" % [what, got, want])

func _realtime() -> Node:
	var realtime: Node = _AsobiRealtimeScript.new(null)
	root.add_child(realtime)
	return realtime

func _feed(realtime: Node, msg: Dictionary) -> void:
	realtime._handle_message(JSON.stringify(msg))

func _read_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()

func _run() -> void:
	_ok_reaches_the_callback()
	_error_reaches_the_callback_with_its_code()
	_an_empty_error_object_still_carries_a_code()
	_signals_fire_with_the_cid()
	_concurrent_calls_correlate_out_of_order()
	_a_reply_is_delivered_once()
	_replies_never_reach_the_dispatch_table()
	_the_canonical_fixtures_correlate()
	print("[rpc] %d passed, %d failed" % [_pass_count, _fail_count])

func _ok_reaches_the_callback() -> void:
	var realtime := _realtime()
	var seen := [null, null]
	var cid: String = realtime.rpc_call("quests.claim", {"quest_key": "daily"},
		func(ok, data): seen[0] = ok; seen[1] = data)
	_feed(realtime, {"type": "rpc.ok", "cid": cid, "payload": {"result": {"reward": 100}}})
	_check("rpc.ok reports success", seen[0], true)
	# 100.0, not 100: JSON has one number type and GDScript decodes it as a
	# float. Worth pinning, because a game comparing a reward to an int
	# literal would silently never match.
	_check("rpc.ok carries the result", seen[1], {"reward": 100.0})

func _error_reaches_the_callback_with_its_code() -> void:
	var realtime := _realtime()
	var seen := [null, null]
	var cid: String = realtime.rpc_call("quests.claim", {}, func(ok, data): seen[0] = ok; seen[1] = data)
	_feed(realtime, {"type": "rpc.error", "cid": cid, "payload": {"error": {
		"code": "quests.already_claimed",
		"message": "This quest was already claimed.",
		"details": {"quest_key": "daily"},
	}}})
	_check("rpc.error reports failure", seen[0], false)
	_check("rpc.error carries the code", seen[1].get("code", ""), "quests.already_claimed")
	_check("rpc.error carries the details", seen[1].get("details", {}), {"quest_key": "daily"})

# A caller branching on `code` must never get an empty string: that is a server
# defect and a domain outcome looking identical.
func _an_empty_error_object_still_carries_a_code() -> void:
	var realtime := _realtime()
	var seen := [null]
	var cid: String = realtime.rpc_call("quests.claim", {}, func(_ok, data): seen[0] = data)
	_feed(realtime, {"type": "rpc.error", "cid": cid, "payload": {}})
	_check("an empty error object falls back to internal", seen[0].get("code", ""), "internal")

func _signals_fire_with_the_cid() -> void:
	var realtime := _realtime()
	var seen := [""]
	realtime.rpc_ok.connect(func(cid, _result): seen[0] = cid)
	var cid: String = realtime.rpc_call("quests.list")
	_feed(realtime, {"type": "rpc.ok", "cid": cid, "payload": {"result": {}}})
	_check("rpc_ok names the call it answers", seen[0], cid)

func _concurrent_calls_correlate_out_of_order() -> void:
	var realtime := _realtime()
	var first := [null]
	var second := [null]
	var cid_a: String = realtime.rpc_call("quests.list", {}, func(_ok, data): first[0] = data)
	var cid_b: String = realtime.rpc_call("quests.claim", {}, func(_ok, data): second[0] = data)
	if cid_a == cid_b:
		_fail("two calls got the same cid")
		return
	_feed(realtime, {"type": "rpc.ok", "cid": cid_b, "payload": {"result": {"n": 2}}})
	_feed(realtime, {"type": "rpc.ok", "cid": cid_a, "payload": {"result": {"n": 1}}})
	_check("the second call gets its own reply", second[0], {"n": 2.0})
	_check("the first call gets its own reply", first[0], {"n": 1.0})

func _a_reply_is_delivered_once() -> void:
	var realtime := _realtime()
	var calls := [0]
	var cid: String = realtime.rpc_call("quests.list", {}, func(_ok, _data): calls[0] += 1)
	var reply := {"type": "rpc.ok", "cid": cid, "payload": {"result": {}}}
	_feed(realtime, reply)
	_feed(realtime, reply)
	_check("a duplicate reply does not call back twice", calls[0], 1)

# A reply belongs to one call, not to every listener bound to the socket.
func _replies_never_reach_the_dispatch_table() -> void:
	var realtime := _realtime()
	var stray := [false]
	realtime.match_event.connect(func(_n, _p): stray[0] = true)
	realtime.world_event.connect(func(_n, _p): stray[0] = true)
	_feed(realtime, {"type": "rpc.ok", "cid": "nobody-is-waiting", "payload": {"result": {}}})
	_check("an uncorrelated reply fires no game event", stray[0], false)

func _the_canonical_fixtures_correlate() -> void:
	for name in ["rpc.ok.json", "rpc.error.json"]:
		var raw := _read_file("%s/%s" % [FIXTURE_DIR, name])
		if raw == "":
			_fail("could not read %s" % name)
			continue
		var fixture: Variant = JSON.parse_string(raw)
		var realtime := _realtime()
		var seen := [null]
		var cid: String = realtime.rpc_call("anything", {}, func(ok, _data): seen[0] = ok)
		fixture["cid"] = cid
		_feed(realtime, fixture)
		_check("%s reaches the caller" % name, seen[0], name == "rpc.ok.json")
