class_name AsobiWire
extends RefCounted

## Decoder for asobi's binary `world.tick` frame.
##
## Same information as the JSON frame in about a quarter of the bytes, and
## measured 2.4x faster to decode here than Godot's native JSON parser: the
## byte loop is forty iterations of native `decode_*` calls, while the parser has
## to chew nearly four kilobytes including forty UUID strings and a hundred and
## sixty float literals. Text parsing loses on volume before interpretation
## overhead matters.
##
## [b]The output is the JSON payload, field for field.[/b] Records arrive on the
## wire as 2-byte slots, and this decoder maps them back to entity ids before it
## hands anything to the game, so [code]world_tick[/code] carries the same
## dictionary either way and nothing downstream has to know which wire delivered
## it. That is the whole point of putting the slot table here.
##
## Layout, every multi-byte value LITTLE-endian - which is why
## [code]decode_*[/code] can be used at all, since Godot ships no big-endian
## counterpart to any of them, and those native calls are the whole reason this
## beats the JSON parser:
## [codeblock]
## frame    Kind:8, ZX:32, ZY:32, FrameSeq:64, Kf:8, Tick:64,
##          DictLen:8, Dict, RecCount:16, Records
## dict     for each name: Len:8, Name/utf8            (at most 32 names)
## record   Op:8, Slot:16, Gen:8, [IdLen:8, Id/utf8]?, FieldCount:8, Fields
## field    Type:3, Idx:5, Value                       (one header byte)
## [/codeblock]

const KIND_SEQUENCED := 1
const KIND_UNGATED := 2

const OP_ADD := 0
const OP_UPDATE := 1
const OP_REMOVE := 2

const T_F32 := 0
const T_I32 := 1
const T_TRUE := 2
const T_FALSE := 3
const T_STR := 4
const T_NULL := 5

# Slot -> entity id, one table per zone. Slot 5 in one zone has nothing to do
# with slot 5 in another, so a single flat table would alias entities across
# zones - the same class of bug that keying entities by zone exists to prevent.
var _slots: Dictionary = {}

## Decodes one frame into the payload dictionary the JSON wire would have sent.
##
## Returns an empty dictionary on malformed bytes rather than raising. These
## bytes come off the network, and a decoder that crashes the game on a truncated
## frame is worse than one that drops it.
func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 28:
		return {}

	var kind := bytes.decode_u8(0)
	if kind != KIND_SEQUENCED and kind != KIND_UNGATED:
		return {}

	var zx := bytes.decode_s32(1)
	var zy := bytes.decode_s32(5)
	var frame_seq := bytes.decode_s64(9)
	var kf := bytes.decode_u8(17) != 0
	var tick := bytes.decode_s64(18)

	var names := PackedStringArray()
	var pos := 26
	var dict_len := bytes.decode_u8(pos)
	pos += 1
	for _i in dict_len:
		if pos >= bytes.size():
			return {}
		var name_len := bytes.decode_u8(pos)
		pos += 1
		if pos + name_len > bytes.size():
			return {}
		names.append(bytes.slice(pos, pos + name_len).get_string_from_utf8())
		pos += name_len

	if pos + 2 > bytes.size():
		return {}
	var rec_count := bytes.decode_u16(pos)
	pos += 2

	var zone_key := "%d:%d" % [zx, zy]
	var table: Dictionary = _slots.get(zone_key, {})
	var updates: Array = []

	for _r in rec_count:
		if pos + 4 > bytes.size():
			return {}
		var op := bytes.decode_u8(pos)
		var slot := bytes.decode_u16(pos + 1)
		# The slot's generation, advancing every time it is rebound to a different
		# entity. Redundant on this ordered, reliable wire and carried anyway, so a
		# client also running the datagram plane can keep ONE slot table for both.
		var gen := bytes.decode_u8(pos + 3)
		pos += 4

		var record := {"gen": gen}
		match op:
			OP_ADD:
				if pos >= bytes.size():
					return {}
				var id_len := bytes.decode_u8(pos)
				pos += 1
				if pos + id_len > bytes.size():
					return {}
				var id := bytes.slice(pos, pos + id_len).get_string_from_utf8()
				pos += id_len
				# An add ESTABLISHES the binding and replaces whatever was
				# there. Slots are reused once freed, so a stale binding that
				# survived an add would attach the wrong entity to every
				# subsequent update on that slot.
				table[slot] = id
				record["op"] = "a"
				record["id"] = id
			OP_UPDATE:
				record["op"] = "u"
				_bind(record, table, slot)
			OP_REMOVE:
				record["op"] = "r"
				_bind(record, table, slot)
			_:
				return {}

		if pos >= bytes.size():
			return {}
		var field_count := bytes.decode_u8(pos)
		pos += 1
		for _f in field_count:
			if pos >= bytes.size():
				return {}
			var header := bytes.decode_u8(pos)
			pos += 1
			var ftype := header >> 5
			var idx := header & 0x1F
			if idx >= names.size():
				return {}
			var key := names[idx]
			match ftype:
				T_F32:
					if pos + 4 > bytes.size():
						return {}
					record[key] = bytes.decode_float(pos)
					pos += 4
				T_I32:
					if pos + 4 > bytes.size():
						return {}
					record[key] = bytes.decode_s32(pos)
					pos += 4
				T_TRUE:
					record[key] = true
				T_FALSE:
					record[key] = false
				T_STR:
					if pos + 2 > bytes.size():
						return {}
					var slen := bytes.decode_u16(pos)
					pos += 2
					if pos + slen > bytes.size():
						return {}
					record[key] = bytes.slice(pos, pos + slen).get_string_from_utf8()
					pos += slen
				T_NULL:
					record[key] = null
				_:
					return {}

		# The binding is released only AFTER the removal is built, so the record
		# that announces an entity's departure still carries its id.
		if op == OP_REMOVE:
			table.erase(slot)

		updates.append(record)

	if pos != bytes.size():
		# Trailing bytes mean the frame and this decoder disagree about the
		# layout. Accepting it would hand the game a half-read frame.
		return {}

	_slots[zone_key] = table

	var payload := {
		"zone": [zx, zy],
		"tick": tick,
		"updates": updates,
	}
	# A sequenced frame holds a position in the zone's stream; an ungated one
	# does not, and says so on the text wire by omitting frame_seq. Omit it here
	# too, so the gap detector treats both wires identically.
	if kind == KIND_SEQUENCED:
		payload["frame_seq"] = frame_seq
		payload["kf"] = kf
	return payload

# An unbound slot means the add that would have established it was lost. The
# record still reports what the frame said - the slot changed - but with no `id`
# key at all, rather than an empty string that looks like a real one. The
# frame_seq gap that caused it is what drives the resync that repairs the mapping.
func _bind(record: Dictionary, table: Dictionary, slot: int) -> void:
	if table.has(slot):
		record["id"] = table[slot]

## The slot-to-id table for one zone, as [code][x, y][/code].
##
## The datagram plane carries slots and this wire carries the bindings, so the
## table is built here and read there. One table rather than two, because two
## would eventually disagree about which entity holds a slot - the same class of
## defect that keying entities by zone exists to close.
func slots_for(zone: Array) -> Dictionary:
	if zone.size() < 2:
		return {}
	return _slots.get("%d:%d" % [int(zone[0]), int(zone[1])], {})

## Forgets every slot binding, for a reconnect.
##
## Bindings are per-session state established by the adds a connection actually
## received, so carrying them across a reconnect would leave stale ids attached
## to slots the server has since handed to different entities. The keyframe that
## follows a reconnect rebuilds the whole table anyway.
func reset() -> void:
	_slots.clear()
