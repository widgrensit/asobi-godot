extends SceneTree

# Binary world.tick decoder test, driven entirely by the server's own committed
# fixture corpus.
#
# The corpus is copied from asobi's priv/wire_fixtures - real bytes from the real
# encoder, with a manifest saying what each one decodes to. Nothing here is
# hand-rolled test data, which is the point: a decoder checked only against a
# fixture the same author invented proves the two agree with each other and
# nothing about whether either matches the server.
#
# Run with:
#   godot --headless --path . -s test/test_binary_wire.gd

const _AsobiWireScript := preload("res://addons/asobi/asobi_wire.gd")

const FIXTURE_DIR := "res://test/fixtures/wire"

var _pass_count := 0
var _fail_count := 0

func _init() -> void:
	var manifest: Variant = _read_json(FIXTURE_DIR + "/manifest.json")
	if not (manifest is Array) or (manifest as Array).is_empty():
		_fail("manifest.json missing or empty")
		_finish()
		return

	for entry in manifest:
		_check_fixture(entry)

	_check_slot_bindings()
	_check_malformed_input_is_dropped()
	_check_reset_forgets_bindings()
	_finish()

# Every fixture must decode to exactly the payload the manifest describes, in the
# JSON wire's own shape - because a game binding world_tick cannot be asked to
# care which wire delivered the frame.
func _check_fixture(entry: Dictionary) -> void:
	var name: String = str(entry.get("name", ""))
	var expected: Dictionary = entry.get("frame", {})
	var bytes := _read_bytes(FIXTURE_DIR + "/" + name + ".bin")
	if bytes.is_empty():
		_fail("%s: fixture bytes missing" % name)
		return
	if bytes.size() != int(entry.get("bytes", -1)):
		_fail("%s: expected %d bytes, read %d" % [name, int(entry.get("bytes", -1)), bytes.size()])
		return

	# A fresh decoder per fixture: the corpus cases are independent frames, not a
	# stream, so sharing slot tables between them would be the test lying.
	var decoder = _AsobiWireScript.new()
	var got: Dictionary = decoder.decode(bytes)
	if got.is_empty():
		_fail("%s: decoded to nothing" % name)
		return

	# The manifest is JSON, so its integers parse as floats. Compare numerically
	# rather than by Array equality, which would fail on 0 != 0.0.
	var expected_zone: Array = expected.get("zone", [])
	var got_zone: Array = got.get("zone", [])
	if got_zone.size() != 2 or int(got_zone[0]) != int(expected_zone[0]) or int(got_zone[1]) != int(expected_zone[1]):
		_fail("%s: zone %s != %s" % [name, str(got_zone), str(expected_zone)])
		return
	if int(got.get("tick", -1)) != int(expected.get("tick", -2)):
		_fail("%s: tick %d != %d" % [name, int(got.get("tick", -1)), int(expected.get("tick", -2))])
		return

	# An ungated frame holds no position in the zone's stream, and says so by
	# having no frame_seq at all. A decoder that reports sequence 0 instead makes
	# the gap detector discard the one frame that clears a leaving zone's ghosts.
	var is_sequenced: bool = str(expected.get("kind", "sequenced")) == "sequenced"
	if is_sequenced:
		if int(got.get("frame_seq", -1)) != int(expected.get("frame_seq", -2)):
			_fail("%s: frame_seq mismatch" % name)
			return
		if bool(got.get("kf", false)) != bool(expected.get("kf", false)):
			_fail("%s: kf mismatch" % name)
			return
	elif got.has("frame_seq"):
		_fail("%s: an ungated frame must carry no frame_seq" % name)
		return

	var expected_records: Array = expected.get("records", [])
	var got_updates: Array = got.get("updates", [])
	if got_updates.size() != expected_records.size():
		_fail("%s: %d updates, expected %d" % [name, got_updates.size(), expected_records.size()])
		return

	for i in expected_records.size():
		var want: Dictionary = expected_records[i]
		var have: Dictionary = got_updates[i]
		var want_op: String = {"add": "a", "update": "u", "remove": "r"}.get(str(want.get("op")), "?")
		if str(have.get("op")) != want_op:
			_fail("%s[%d]: op %s != %s" % [name, i, str(have.get("op")), want_op])
			return
		# The id is present on an add, which is where the binding is established.
		if want.has("id") and str(have.get("id")) != str(want.get("id")):
			_fail("%s[%d]: id %s != %s" % [name, i, str(have.get("id")), str(want.get("id"))])
			return
		var want_fields: Dictionary = want.get("fields", {})
		for key in want_fields:
			if not have.has(key):
				_fail("%s[%d]: missing field %s" % [name, i, key])
				return
			if not _values_match(have[key], want_fields[key]):
				_fail("%s[%d]: %s = %s, expected %s" % [name, i, key, str(have[key]), str(want_fields[key])])
				return

	_pass(name)

# The reason the slot table lives in the decoder: an update carries the slot
# alone, and a game must still see the entity id it saw on the add.
func _check_slot_bindings() -> void:
	var decoder = _AsobiWireScript.new()
	var kf := _read_bytes(FIXTURE_DIR + "/keyframe_all_adds.bin")
	var frame: Dictionary = decoder.decode(kf)
	if frame.is_empty():
		_fail("slot bindings: keyframe did not decode")
		return
	var ids: Array = []
	for u in frame.get("updates", []):
		ids.append(str(u.get("id")))
	if ids.is_empty() or ids.has(""):
		_fail("slot bindings: keyframe adds carried no ids")
		return

	# The keyframe is zone [-1, -1]. A frame for a DIFFERENT zone must not resolve
	# against its table - slot 1 in one zone has nothing to do with slot 1 in
	# another, and aliasing them is the corruption per-zone tables exist to stop.
	var other: Dictionary = decoder.decode(_read_bytes(FIXTURE_DIR + "/removes_only.bin"))
	if other.is_empty():
		_fail("slot bindings: second frame did not decode")
		return
	for u in other.get("updates", []):
		if u.has("id") and ids.has(str(u.get("id"))):
			_fail("slot bindings: a slot resolved across zones")
			return
	_pass("slot bindings are scoped per zone")

# These bytes arrive off the network. A decoder that crashes the game on a
# truncated frame is worse than one that drops it.
func _check_malformed_input_is_dropped() -> void:
	var good := _read_bytes(FIXTURE_DIR + "/steady_state_40_updates.bin")
	var cases := {
		"empty": PackedByteArray(),
		"one byte": PackedByteArray([1]),
		"truncated envelope": good.slice(0, 10),
		"truncated mid-record": good.slice(0, good.size() - 2),
		"trailing junk": good + PackedByteArray([0, 0, 0]),
		"unknown kind byte": PackedByteArray([9]) + good.slice(1),
	}
	for label in cases:
		var decoder = _AsobiWireScript.new()
		if not decoder.decode(cases[label]).is_empty():
			_fail("malformed input accepted: %s" % label)
			return
	_pass("malformed frames are dropped, not decoded")

# Bindings belong to one connection's stream of adds. Kept across a reconnect they
# would attach stale ids to slots the server has since reassigned.
func _check_reset_forgets_bindings() -> void:
	var decoder = _AsobiWireScript.new()
	var _kf: Dictionary = decoder.decode(_read_bytes(FIXTURE_DIR + "/keyframe_all_adds.bin"))
	decoder.reset()
	var after: Dictionary = decoder.decode(_read_bytes(FIXTURE_DIR + "/removes_only.bin"))
	for u in after.get("updates", []):
		if u.has("id"):
			_fail("reset() left a binding behind")
			return
	_pass("reset() forgets every binding")

# float32 on the wire against a float64 in the manifest, so compare with a
# tolerance rather than for equality - 12.5 survives exactly, 1.5 * 7 does not.
func _values_match(got: Variant, want: Variant) -> bool:
	if got is float and (want is float or want is int):
		return absf(float(got) - float(want)) < 0.0001
	return got == want

func _read_bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b

func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return JSON.parse_string(text)

func _pass(msg: String) -> void:
	_pass_count += 1
	print("[binary-wire] PASS: ", msg)

func _fail(msg: String) -> void:
	_fail_count += 1
	printerr("[binary-wire] FAIL: ", msg)

func _finish() -> void:
	print("[binary-wire] %d passed, %d failed" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)
