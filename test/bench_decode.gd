extends SceneTree

## Decode-cost benchmark: a fixed-layout binary world.tick against the JSON one.
##
## Gate 11.4 of the transport design blocks the binary codec outright if this
## loses: Godot's JSON parser is native C++, and a byte-loop decoder in
## interpreted GDScript is not. Losing here does not kill the codec, it makes it
## a per-SDK negotiation rather than a fleet-wide wire - which is a decision worth
## taking before the format is written rather than after.
##
## Run: godot --headless --path . -s test/bench_decode.gd

const RECORDS := 40
const ITERS := 300

# One record: op u8, id u16, field mask u8, then x/y/vx/vy as float32. 20 bytes.
# Matches the packed layout the design costs at 807 B for 40 records, against
# the JSON frame's ~5.9 KB at 400 entities / 10% churn.
const REC_SIZE := 20

func _build_binary() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(7 + RECORDS * REC_SIZE)
	buf.encode_u8(0, 1)          # frame type
	buf.encode_u32(1, 4711)      # tick
	buf.encode_u16(5, RECORDS)   # count
	var off := 7
	for i in RECORDS:
		buf.encode_u8(off, 1)                      # op: update
		buf.encode_u16(off + 1, i)                 # connection-local id
		buf.encode_u8(off + 3, 0x0F)               # mask: x,y,vx,vy present
		buf.encode_float(off + 4, 100.0 + i)
		buf.encode_float(off + 8, 200.0 + i)
		buf.encode_float(off + 12, 1.5)
		buf.encode_float(off + 16, -0.5)
		off += REC_SIZE
	return buf

func _build_json() -> String:
	# The real wire: UUIDv7 ids as 36-char strings, which is part of why the
	# binary frame is smaller. Kept faithful so the CPU comparison is against
	# what actually gets decoded today, not a slimmed-down stand-in.
	var updates := []
	for i in RECORDS:
		updates.append({
			"op": "u",
			"id": "01a0115f-547e-714f-829f-408c855ab%03d" % i,
			"x": 100.0 + i, "y": 200.0 + i, "vx": 1.5, "vy": -0.5,
		})
	return JSON.stringify({
		"type": "world.tick",
		"payload": {"zone": [0, 0], "frame_seq": 17, "kf": false, "tick": 4711, "updates": updates},
	})

## Decodes into the same shape JSON.parse_string produces - an Array of
## Dictionaries - so the comparison is decode-to-usable-structure both ways. A
## reader that only walked bytes without building objects would flatter binary.
func _decode_binary(buf: PackedByteArray) -> Array:
	var count := buf.decode_u16(5)
	var out := []
	out.resize(count)
	var off := 7
	for i in count:
		var mask := buf.decode_u8(off + 3)
		var rec := {"op": buf.decode_u8(off), "id": buf.decode_u16(off + 1)}
		if mask & 0x01: rec["x"] = buf.decode_float(off + 4)
		if mask & 0x02: rec["y"] = buf.decode_float(off + 8)
		if mask & 0x04: rec["vx"] = buf.decode_float(off + 12)
		if mask & 0x08: rec["vy"] = buf.decode_float(off + 16)
		out[i] = rec
		off += REC_SIZE
	return out

func _init() -> void:
	var bin := _build_binary()
	var txt := _build_json()

	# Warm both paths so neither pays first-call cost in the measured loop.
	var _w1 := _decode_binary(bin)
	var _w2: Variant = JSON.parse_string(txt)

	var t0 := Time.get_ticks_usec()
	for _i in ITERS:
		var a := _decode_binary(bin)
		if a.size() != RECORDS: push_error("binary decode wrong size")
	var bin_us := float(Time.get_ticks_usec() - t0) / ITERS

	t0 = Time.get_ticks_usec()
	for _i in ITERS:
		var d: Variant = JSON.parse_string(txt)
		if d["payload"]["updates"].size() != RECORDS: push_error("json decode wrong size")
	var json_us := float(Time.get_ticks_usec() - t0) / ITERS

	print("records:      %d   iterations: %d" % [RECORDS, ITERS])
	print("binary bytes: %d" % bin.size())
	print("json bytes:   %d" % txt.length())
	print("")
	print("binary decode: %8.1f us/frame" % bin_us)
	print("json decode:   %8.1f us/frame" % json_us)
	if bin_us < json_us:
		print("=> binary is %.2fx FASTER to decode" % (json_us / bin_us))
	else:
		print("=> binary is %.2fx SLOWER to decode" % (bin_us / json_us))
	quit(0)
