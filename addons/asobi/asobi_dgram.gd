class_name AsobiDgram
extends RefCounted

## Codec for asobi's datagram plane.
##
## Mirrors [code]asobi/src/dgram/asobi_dgram.erl[/code] and the Lua SDKs'
## [code]asobi/dgram.lua[/code]. Pure: no sockets, no clock, no state, so every
## byte-level decision here is testable headless.
##
## Layout, every multi-byte value little-endian - the same choice the binary
## [code]world.tick[/code] wire makes, and for the same reason: Godot's byte
## readers have no big-endian counterpart, and one carrier in each byte order is
## a trap nobody would thank us for.
##
## [codeblock]
## prefix(16)  Magic:8=0xA5, Version:8, Opcode:8, Flags:8, ConnId:32, PathTag:64
## uplink      prefix, CSeq:64, <body>, Mac:16
## downlink    prefix, <body>                       (no MAC - see below)
##
## pose body   Tick:32, BSeq:32, ZoneX:16, ZoneY:16, FieldMask:8, Count:8,
##             Epoch:16, Records
## record      Slot:16, Gen:8, RMask:8, [Value:16/signed]*
## [/codeblock]
##
## [b]The downlink carries no MAC and no encryption.[/b] Stated plainly because it
## is a real reduction: the plane provides off-path forgery resistance and no
## confidentiality or on-path integrity. Everything with authority travels only on
## the TLS WebSocket. A forged pose can make this client's own render of other
## entities wrong for one interval and nothing else - it cannot create or remove
## an entity or touch a state field, because a record has nowhere to say so.

const MAGIC := 0xA5
const VERSION := 1

const OP_HELLO := 1
const OP_HELLO_OK := 2
const OP_HELLO_CONFIRM := 3
const OP_BYE := 4
const OP_PING := 5
const OP_PONG := 6
const OP_POSE := 7
const OP_INPUT := 8

## The floor a `hello` is padded to. An anti-amplification control rather than
## framing: the server drops a short hello BEFORE doing MAC work, so no reply can
## ever be larger than the request that caused it.
const MIN_HELLO := 64
const MAC_BYTES := 16
const PREFIX_BYTES := 16
const CSEQ_BYTES := 8
const POSE_HEADER_BYTES := 16

## Builds one authenticated uplink datagram.
##
## The padding goes INSIDE the MAC's coverage. Appended after the tag it would
## both break verification and let an attacker strip it back off to recover the
## amplification ratio it exists to remove.
static func encode_uplink(
	opcode: int, conn_id: int, cseq: int, body: PackedByteArray, key: PackedByteArray, pad_to: int
) -> PackedByteArray:
	var padded := body.duplicate()
	var floor_len := pad_to - PREFIX_BYTES - CSEQ_BYTES - MAC_BYTES
	while padded.size() < floor_len:
		padded.append(0)

	var signed := PackedByteArray()
	signed.append(MAGIC)
	signed.append(VERSION)
	signed.append(opcode)
	# Every flag bit is reserved and must be zero.
	signed.append(0)
	_append_u32(signed, conn_id)
	# path_tag is always zero on an uplink: there is no return-path handle for a
	# client to carry, and the server refuses a non-zero one rather than parsing
	# whatever was smuggled in it.
	for _i in 8:
		signed.append(0)
	_append_u64(signed, cseq)
	signed.append_array(padded)

	var out := signed.duplicate()
	out.append_array(mac(signed, key))
	return out


## HMAC-SHA256 truncated to 128 bits, the tag every uplink datagram carries.
static func mac(message: PackedByteArray, key: PackedByteArray) -> PackedByteArray:
	var ctx := HMACContext.new()
	if ctx.start(HashingContext.HASH_SHA256, key) != OK:
		return PackedByteArray()
	if ctx.update(message) != OK:
		return PackedByteArray()
	return ctx.finish().slice(0, MAC_BYTES)


## Decodes one datagram from the gateway, or an empty dictionary.
##
## Total by construction: these bytes arrive unauthenticated from anywhere, so a
## decoder that raised would hand anyone on the path a way to crash the game.
static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < PREFIX_BYTES:
		return {}
	if bytes.decode_u8(0) != MAGIC or bytes.decode_u8(1) != VERSION:
		return {}
	# A reserved bit is a drop rather than a mask-and-continue, which is what
	# stops a flag defined later being silently ignored by an old client.
	if bytes.decode_u8(3) != 0:
		return {}
	return {
		"opcode": bytes.decode_u8(2),
		"conn_id": bytes.decode_u32(4),
		"body": bytes.slice(PREFIX_BYTES),
	}


## Decodes a pose body, or an empty dictionary.
##
## [param field_count] is the length of the manifest the mint response delivered.
## The wire carries no field names at all, which is what lets this be a byte loop
## rather than a parser.
static func decode_pose(body: PackedByteArray, field_count: int) -> Dictionary:
	if body.size() < POSE_HEADER_BYTES:
		return {}
	var tick := body.decode_u32(0)
	var bseq := body.decode_u32(4)
	var zx := body.decode_s16(8)
	var zy := body.decode_s16(10)
	var fieldmask := body.decode_u8(12)
	var count := body.decode_u8(13)
	var epoch := body.decode_u16(14)

	var pos := POSE_HEADER_BYTES
	var records: Array = []
	for _r in count:
		if pos + 4 > body.size():
			return {}
		var slot := body.decode_u16(pos)
		var gen := body.decode_u8(pos + 2)
		var rmask := body.decode_u8(pos + 3)
		pos += 4
		var values: Array = []
		values.resize(field_count)
		for f in field_count:
			if rmask & (1 << f) != 0:
				if pos + 2 > body.size():
					return {}
				values[f] = body.decode_s16(pos)
				pos += 2
		records.append({"slot": slot, "gen": gen, "values": values})

	if pos != body.size():
		# Trailing bytes mean this decoder and the frame disagree about the
		# layout, and a half-read frame is worse than a dropped one.
		return {}

	return {
		"tick": tick,
		"bseq": bseq,
		"zone": [zx, zy],
		"fieldmask": fieldmask,
		"epoch": epoch,
		"records": records,
	}


static func _append_u32(out: PackedByteArray, n: int) -> void:
	for i in 4:
		out.append((n >> (i * 8)) & 0xFF)


static func _append_u64(out: PackedByteArray, n: int) -> void:
	for i in 8:
		out.append((n >> (i * 8)) & 0xFF)
