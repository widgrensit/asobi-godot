extends SceneTree

# The datagram plane's codec, state machine and two-carrier merge.
#
# Every timing is driven by an injected clock, so the probe ladder, the hard
# give-up, the keepalive and the degradation threshold are asserted rather than
# waited for.
#
# Run with:
#   godot --headless --path . -s test/test_datagram.gd

const _DgramScript := preload("res://addons/asobi/asobi_dgram.gd")
const _DatagramScript := preload("res://addons/asobi/asobi_datagram.gd")
const _EntitiesScript := preload("res://addons/asobi/asobi_entities.gd")

const CONN := 4711
const KUP := "0123456789abcdef0123456789abcdef"

var _pass := 0
var _fail := 0

func _init() -> void:
	_codec()
	_state_machine()
	_merge_rule()
	print("[datagram] %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- Codec ---

func _codec() -> void:
	var key := KUP.to_utf8_buffer()
	var hello := AsobiDgram.encode_uplink(
		AsobiDgram.OP_HELLO, CONN, 1, PackedByteArray(), key, AsobiDgram.MIN_HELLO
	)
	_check(hello.size() >= AsobiDgram.MIN_HELLO, "hello is padded to the anti-amplification floor")
	_check(hello.decode_u8(0) == AsobiDgram.MAGIC, "magic")
	_check(hello.decode_u32(4) == CONN, "conn_id is little-endian at bytes 4-7")

	# An uplink carries no return-path handle, and the server refuses a non-zero
	# one rather than parsing whatever was smuggled in it.
	var tag_zero := true
	for i in range(8, 16):
		if hello.decode_u8(i) != 0:
			tag_zero = false
	_check(tag_zero, "an uplink carries no path_tag")

	# The MAC covers every byte before it, padding included - appended after the
	# tag the padding could simply be stripped back off.
	var expected := AsobiDgram.mac(hello.slice(0, hello.size() - AsobiDgram.MAC_BYTES), key)
	_check(expected == hello.slice(hello.size() - AsobiDgram.MAC_BYTES), "the tag covers the frame")

	# Total on hostile input: these bytes arrive unauthenticated from anywhere.
	var junk: Array = [
		PackedByteArray(),
		PackedByteArray([1]),
		PackedByteArray([0xA5, 9, 1, 0]),
	]
	for bytes in junk:
		_check(AsobiDgram.decode(bytes).is_empty(), "malformed input is refused")

	# A reserved flag bit is a drop rather than a mask, so a flag defined later
	# cannot be silently ignored by an old client.
	var flagged := PackedByteArray([AsobiDgram.MAGIC, AsobiDgram.VERSION, AsobiDgram.OP_POSE, 1])
	flagged.resize(16)
	_check(AsobiDgram.decode(flagged).is_empty(), "a reserved flag bit is refused")

	var pose := AsobiDgram.decode_pose(_pose_body(42, 7, 3, -2, 9, [[5, 2, 0b11, [1250, -325]]]), 2)
	_check(not pose.is_empty(), "a pose body decodes")
	_check(int(pose["tick"]) == 42 and int(pose["bseq"]) == 7, "tick and bseq")
	_check(pose["zone"] == [3, -2], "zone coords are signed")
	_check(int(pose["epoch"]) == 9, "epoch")
	var rec: Dictionary = pose["records"][0]
	_check(int(rec["slot"]) == 5 and int(rec["gen"]) == 2, "slot and gen")
	_check(rec["values"] == [1250, -325], "values, signed")

	var body := _pose_body(1, 0, 0, 0, 0, [[1, 0, 0b1, [7]]])
	body.append(0)
	_check(AsobiDgram.decode_pose(body, 1).is_empty(), "trailing bytes are refused")

# --- State machine ---

func _state_machine() -> void:
	var sent: Array = []
	var dg: AsobiDatagram = _new_datagram(sent)
	_check(dg.state == AsobiDatagram.State.OFF, "a fresh client is off")
	_check(not dg.pose_authoritative(), "off is never authoritative")

	# The probe ladder: 200 / 400 / 800ms, then a hard stop at three seconds. A
	# client that retried forever would sit behind a firewall that will never
	# pass UDP, reporting nothing.
	_mint(dg, 0.0)
	_check(dg.state == AsobiDatagram.State.PROBING, "a mint moves to probing")
	dg.update(0.0)
	_check(sent.size() == 1, "the first hello goes immediately")
	dg.update(0.1)
	_check(sent.size() == 1, "no retry before the backoff")
	dg.update(0.2)
	_check(sent.size() == 2, "the first retry is at 200ms")
	# 0.61 rather than 0.6: the deadline is a sum of floats and lands a hair past
	# it, and a real client polls on frame boundaries anyway.
	dg.update(0.61)
	_check(sent.size() == 3, "the second retry is 400ms later")
	dg.update(3.0)
	_check(dg.state == AsobiDatagram.State.OFF, "probing gives up at three seconds")
	_check(dg.conn_id == 0, "giving up forgets the credential")

	# Nothing is authoritative until pose actually arrives: the server sends none
	# until the challenge is echoed.
	sent.clear()
	dg = _new_datagram(sent)
	_mint(dg, 0.0)
	dg.update(0.0)
	var challenge := PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	_check(dg.on_datagram(_downlink(AsobiDgram.OP_HELLO_OK, CONN, challenge), 0.05).is_empty(),
		"hello_ok yields no pose")
	_check(sent.size() == 2, "hello_ok is answered with a confirm")
	_check(not dg.pose_authoritative(), "a confirm alone is not enough")

	var pose_raw := _downlink(AsobiDgram.OP_POSE, CONN, _pose_body(1, 0, 0, 0, 9, []))
	_check(not dg.on_datagram(pose_raw, 0.1).is_empty(), "a pose decodes")
	_check(dg.pose_authoritative(), "the first pose is what makes the plane active")

	# A datagram naming another connection is a stale mapping or a stray packet,
	# and applying it would apply another player's world.
	_check(dg.on_datagram(_downlink(AsobiDgram.OP_POSE, 1, _pose_body(1, 0, 0, 0, 9, [])), 0.2).is_empty(),
		"another connection's pose is ignored")

	# A frame from before an engine restart. The epoch is what makes that
	# detectable at all.
	_check(dg.on_datagram(_downlink(AsobiDgram.OP_POSE, CONN, _pose_body(1, 0, 0, 0, 77, [])), 0.2).is_empty(),
		"a pose from another epoch is dropped")

	# Degradation, which is the fallback the design insists ships with the
	# carrier: transform fields go straight back to world.tick.
	var before := sent.size()
	dg.update(2.2)
	_check(dg.state == AsobiDatagram.State.DEGRADED, "two seconds without pose degrades")
	_check(not dg.pose_authoritative(), "degraded hands transforms back to world.tick")
	_check(sent.size() > before, "degrading re-sends hello")

	# The keepalive is the client's job and nothing else can do it: with a NAT in
	# the path a quiet client loses its mapping and the downlink is blackholed
	# with no signal at all.
	sent.clear()
	dg = _new_datagram(sent)
	_mint(dg, 0.0)
	var live := _downlink(AsobiDgram.OP_POSE, CONN, _pose_body(1, 0, 0, 0, 9, []))
	dg.on_datagram(live, 0.0)
	sent.clear()
	# Pose has to keep arriving, or the connection degrades long before the
	# keepalive is due - which is itself the right behaviour and is asserted
	# above. This isolates the ping timer from the degradation timer.
	dg.on_datagram(live, AsobiDatagram.KEEPALIVE - 0.1)
	dg.update(AsobiDatagram.KEEPALIVE - 0.1)
	_check(sent.size() == 0, "no ping before the interval")
	dg.on_datagram(live, AsobiDatagram.KEEPALIVE)
	dg.update(AsobiDatagram.KEEPALIVE)
	_check(sent.size() == 1, "a ping at the interval")
	dg.update(AsobiDatagram.KEEPALIVE + 0.1)
	_check(sent.size() == 1, "and only one")

	# Input is refused while not active, and the caller then sends it over the
	# WebSocket - an input must never be lost because the plane was between
	# states.
	dg.stop()
	_check(not dg.send_input(PackedByteArray([1])), "input is refused while not active")

# --- The merge rule ---

func _merge_rule() -> void:
	var e: AsobiEntities = _EntitiesScript.new()
	e.set_transform_fields(PackedStringArray(["x", "y"]))

	# Keyed on zone. A crossing emits a remove from the zone being left and an
	# add from the zone being entered, from two senders with no order between
	# them, so applying both into one namespace deletes the entity for good.
	e.apply_tick({"zone": [0, 0], "tick": 1, "updates": [
		{"op": "a", "id": "e1", "x": 1.0, "y": 2.0},
	]})
	e.apply_tick({"zone": [1, 0], "tick": 2, "updates": [
		{"op": "a", "id": "e1", "x": 9.0, "y": 2.0},
	]})
	e.apply_tick({"zone": [0, 0], "tick": 2, "updates": [{"op": "r", "id": "e1"}]})
	_check(e.get_entity("e1").get("x") == 9.0, "a remove from the zone it left cannot delete it")

	# A pose only applies to the zone that owns the entity, and never creates one.
	var slots := {5: "e1"}
	e.apply_pose(_pose(1, [1, 0], 10, [[5, 0, [500, 200]]]), slots, _fields())
	_check(e.get_entity("e1").get("x") == 5.0, "a pose applies where the zone owns the entity")

	e.apply_pose(_pose(1, [1, 0], 20, [[9, 0, [100, 100]]]), {}, _fields())
	_check(not e.all().has("9"), "a pose can never create an entity")

	# A world.tick transform loses to a fresher pose; a state field never does,
	# because world.tick is its only carrier.
	e.apply_tick({"zone": [1, 0], "tick": 5, "updates": [
		{"op": "u", "id": "e1", "x": 99.0, "hp": 42},
	]})
	_check(e.get_entity("e1").get("x") == 5.0, "a stale world.tick transform loses to the pose")
	_check(e.get_entity("e1").get("hp") == 42, "a state field applies unconditionally")

	# ...and a fresher world.tick wins, or a stopped entity would never correct.
	e.apply_tick({"zone": [1, 0], "tick": 20, "updates": [{"op": "u", "id": "e1", "x": 7.0}]})
	_check(e.get_entity("e1").get("x") == 7.0, "a fresher world.tick transform wins")

	# A stale pose loses too, in the other direction.
	e.apply_pose(_pose(1, [1, 0], 5, [[5, 0, [111, 0]]]), slots, _fields())
	_check(e.get_entity("e1").get("x") == 7.0, "a stale pose is dropped")

	# A keyframe carries tick 0, so taking it verbatim would let a stale
	# in-flight pose apply over fresher state on every subscribe.
	var before: int = e.get_entity("e1").get("x")
	e.apply_tick({"zone": [1, 0], "tick": 0, "kf": true, "updates": [
		{"op": "a", "id": "e1", "x": 3.0, "y": 3.0},
	]})
	e.apply_pose(_pose(1, [1, 0], 1, [[5, 0, [800, 0]]]), slots, _fields())
	_check(e.get_entity("e1").get("x") == 3.0, "a keyframe must not rewind the pose clock")
	_check(before != null, "state existed before the keyframe")

	# A keyframe is the whole of its zone, so anything absent went away while we
	# were not listening.
	e.apply_tick({"zone": [1, 0], "tick": 30, "updates": [
		{"op": "a", "id": "e2", "x": 0.0, "y": 0.0},
	]})
	e.apply_tick({"zone": [1, 0], "tick": 0, "kf": true, "updates": [
		{"op": "a", "id": "e2", "x": 0.0, "y": 0.0},
	]})
	_check(not e.all().has("e1"), "a keyframe reconciles away what it omits")

	# An update for something never added invents nothing: the add is lost or on
	# its way, and the resync a frame_seq gap triggers is what repairs it.
	e.apply_tick({"zone": [1, 0], "tick": 40, "updates": [{"op": "u", "id": "ghost", "x": 1.0}]})
	_check(not e.all().has("ghost"), "an update never invents an entity")

# --- Helpers ---

func _new_datagram(sent: Array) -> AsobiDatagram:
	var dg: AsobiDatagram = _DatagramScript.new()
	dg.send = func(bytes: PackedByteArray) -> void: sent.append(bytes)
	return dg

func _mint(dg: AsobiDatagram, now: float) -> void:
	dg.on_mint(CONN, KUP.to_utf8_buffer(), 9, _fields(), now)

func _fields() -> Array:
	return [{"name": "x", "scale": 100}, {"name": "y", "scale": 100}]

func _pose(tick: int, zone: Array, pose_tick: int, records: Array) -> Dictionary:
	var out: Array = []
	for r in records:
		out.append({"slot": r[0], "gen": r[1], "values": r[2]})
	return {"tick": pose_tick, "bseq": 0, "zone": zone, "epoch": 9, "records": out}

func _downlink(opcode: int, conn: int, body: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([AsobiDgram.MAGIC, AsobiDgram.VERSION, opcode, 0])
	for i in 4:
		out.append((conn >> (i * 8)) & 0xFF)
	for _i in 8:
		out.append(0)
	out.append_array(body)
	return out

func _pose_body(tick: int, bseq: int, zx: int, zy: int, epoch: int, records: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(16)
	out.encode_u32(0, tick)
	out.encode_u32(4, bseq)
	out.encode_s16(8, zx)
	out.encode_s16(10, zy)
	out.encode_u8(12, 0b11)
	out.encode_u8(13, records.size())
	out.encode_u16(14, epoch)
	for r in records:
		var rec := PackedByteArray()
		rec.resize(4)
		rec.encode_u16(0, r[0])
		rec.encode_u8(2, r[1])
		rec.encode_u8(3, r[2])
		out.append_array(rec)
		for v in r[3]:
			var val := PackedByteArray()
			val.resize(2)
			val.encode_s16(0, v)
			out.append_array(val)
	return out

func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("[datagram] PASS: ", msg)
	else:
		_fail += 1
		printerr("[datagram] FAIL: ", msg)
