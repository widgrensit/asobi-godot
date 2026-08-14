class_name AsobiRealtime
extends Node

signal connected
signal disconnected(reason: String)
signal session_revoked
signal heartbeat(payload: Dictionary)
signal match_matched(payload: Dictionary)
signal match_joined(payload: Dictionary)
signal match_left(payload: Dictionary)
signal match_state(payload: Dictionary)
signal match_finished(payload: Dictionary)
signal match_list_received(payload: Dictionary)
signal match_event(event_name: String, payload: Dictionary)
signal chat_message(payload: Dictionary)
signal chat_joined(payload: Dictionary)
signal chat_left(payload: Dictionary)
signal dm_message(payload: Dictionary)
signal dm_sent(payload: Dictionary)
signal notification_received(payload: Dictionary)
signal matchmaker_queued(payload: Dictionary)
signal matchmaker_removed(payload: Dictionary)
signal matchmaker_expired(payload: Dictionary)
signal matchmaker_failed(payload: Dictionary)
signal presence_updated(payload: Dictionary)
signal error_received(payload: Dictionary)
# Dev-mode only: a Lua callback error while handling this player's input.
# Gated server-side behind ASOBI_DEV_ERRORS=true; production keeps script
# errors server-side.
signal game_error(callback: String, script: String, message: String)
# Unconditional server push for game.send(player_id, message) (production and
# dev both). The payload is a Dictionary with a "message" key whose value can
# be a String, number, bool, null, Array, or nested Dictionary - Lua can send
# any JSON-representable value via game.send/2. The server deliberately wraps
# the value in {"message": <value>} rather than sending it bare, so it can
# carry more fields later without a breaking change; this signal keeps the
# wrapper Dictionary intact for the same reason (unwrapping to a single
# positional param would make adding a second field a breaking signal-arity
# change). Connect with an untyped/Variant-accepting callable and branch on
# typeof(payload.get("message")) rather than assuming a fixed type.
signal game_message(payload: Dictionary)
signal vote_cast_ok(payload: Dictionary)
signal vote_veto_ok(payload: Dictionary)
# Server-pushed vote lifecycle (asobi broadcasts these as match.vote_*).
signal vote_start(payload: Dictionary)
signal vote_tally(payload: Dictionary)
signal vote_result(payload: Dictionary)
signal vote_vetoed(payload: Dictionary)
signal world_joined(payload: Dictionary)
signal world_left(payload: Dictionary)
signal world_tick(payload: Dictionary)
signal world_terrain(coords: Vector2i, data: String)
signal world_list_received(payload: Dictionary)
signal world_phase_changed(payload: Dictionary)
signal world_finished(payload: Dictionary)
## Fires on `world.ack` - the server's acknowledgement of the highest
## `world.input` `seq` it has consumed for you as of the payload's `tick`. Sent
## only to players that stamped a `seq` on their input; use it to reconcile
## client-side prediction. Payload keys: `tick`, `seq` - both floats, because
## `JSON.parse_string` decodes every JSON number as one; cast with `int()`.
##
## On a broadcast that produced deltas `world.tick` arrives first and
## `world.ack` second; on a broadcast where nothing changed the ack arrives
## alone, with no `world.tick` before it. Prune the pending-input buffer and
## replay it here rather than on the tick.
signal world_ack(payload: Dictionary)
signal world_event(event_name: String, payload: Dictionary)

## An extension's RPC method answered. `cid` is what `rpc()` returned, so a
## listener can tell its own call's reply from somebody else's.
signal rpc_ok(cid: String, result: Dictionary)
## An extension's RPC method refused. `error` is the shared error object:
## `code`, `message`, `details`. Branch on `code` - `message` is prose for a
## human and may change.
signal rpc_error(cid: String, error: Dictionary)
## A named push from an extension, unsolicited (unlike `rpc_ok`). Route on
## `payload.module` (which extension) and `payload.event` (e.g.
## `quests.completed`); `payload.data` carries the event body. The event name
## is data, not a dispatch gate - an unfamiliar name still surfaces here. The
## whole payload passes through so a new field never breaks a shipped game.
signal module_event(payload: Dictionary)

var _client: AsobiClient
var _socket := WebSocketPeer.new()
var _is_connected := false
var _is_connecting := false
var _cid_counter := 0
var _pending: Dictionary = {}
var _revoked := false

func _init(client: AsobiClient) -> void:
	_client = client

func _process(_delta: float) -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		if _is_connected or _is_connecting:
			_is_connected = false
			_is_connecting = false
			var reason := _socket.get_close_reason()
			if reason == "session_revoked" or reason == "invalid_token":
				_revoked = true
				session_revoked.emit()
			else:
				disconnected.emit(reason if reason != "" else "closed")
		return

	_socket.poll()

	if _is_connecting and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_is_connecting = false
		_is_connected = true
		_send("session.connect", {"token": _client.access_token})

	while _socket.get_available_packet_count() > 0:
		var data := _socket.get_packet().get_string_from_utf8()
		_handle_message(data)

func connect_to_server() -> void:
	if _is_connected or _is_connecting:
		return
	_revoked = false
	var err := _socket.connect_to_url(_client.ws_url)
	if err != OK:
		push_error("Asobi WebSocket connect failed: %d" % err)
		return
	_is_connecting = true

func disconnect_from_server() -> void:
	_socket.close()
	_is_connected = false
	_is_connecting = false
	_pending.clear()

# Re-authenticate the socket after the access_token rotates. If already
# connected, re-send session.connect with the fresh token; if the socket
# dropped for a non-revoked reason, reconnect. A revoked session must go
# through a full re-login, so we never reconnect with a dead token here.
func reauthenticate() -> void:
	if _revoked:
		return
	if _is_connected:
		_send("session.connect", {"token": _client.access_token})
	elif not _is_connecting:
		connect_to_server()

# Match
# has_capacity must be a JSON boolean and is only sent when true; the backend
# shares its filter validator with world.list and rejects anything else with
# "invalid_has_capacity_filter". The reply arrives as match_list_received.
func match_list(mode: String = "", has_capacity: bool = false) -> void:
	var payload := {}
	if mode != "":
		payload["mode"] = mode
	if has_capacity:
		payload["has_capacity"] = true
	_send("match.list", payload)

# `ctx` is an optional join context the server hands to the game module
# untouched - an invite code, a password, a lobby slot. asobi never interprets
# it, but it does bound it: at most 8 keys, keys up to 64 bytes, values that
# are String, int or bool up to 256 bytes. Anything else is rejected with an
# error frame. Omitted entirely when empty.
func join_match(match_id: String, ctx: Dictionary = {}) -> void:
	var payload := {"match_id": match_id}
	if not ctx.is_empty():
		payload["ctx"] = ctx
	_send("match.join", payload)

# The match twin of world_find_or_create: get into a live match of `mode`,
# spawning one if there is none. Prefer it over match_list then join_match,
# which races - two clients reading the same empty listing each create a match.
# This resolves server-side and is serialized, so simultaneous callers converge
# on one match.
#
# `mode` is the only match parameter you supply; every other one comes from the
# server-side mode config. `ctx` is the same optional join context join_match
# takes, bounded the same way, omitted when empty and handed to the game's join
# callback just as match.join's is.
#
# The reply is match.joined, so it arrives on the match_joined signal exactly
# as join_match's does. Refusals arrive as error frames and include not_found
# (the mode name is unknown or not configured), quick_play_disabled (the mode
# has not set quick_play, which defaults to false for match modes),
# match_capacity_reached, wrong_mode_type (a world mode) and join_rate_limited.
#
# Needs an asobi server >= v0.86.0.
func match_find_or_create(mode: String, ctx: Dictionary = {}) -> void:
	var payload := {"mode": mode}
	if not ctx.is_empty():
		payload["ctx"] = ctx
	_send("match.find_or_create", payload)

func send_match_input(input: Dictionary) -> void:
	_send_fire_and_forget("match.input", input)

func leave_match() -> void:
	_send("match.leave", {})

# Matchmaker
# The backend reads `mode` and `properties` only - there is no party queueing
# on the wire, so nothing else belongs in this frame.
func add_to_matchmaker(mode: String = "default", properties: Dictionary = {}) -> void:
	var payload := {"mode": mode}
	if not properties.is_empty():
		payload["properties"] = properties
	_send("matchmaker.add", payload)

func remove_from_matchmaker(ticket_id: String) -> void:
	_send("matchmaker.remove", {"ticket_id": ticket_id})

# Chat
func join_chat(channel_id: String) -> void:
	_send("chat.join", {"channel_id": channel_id})

func send_chat_message(channel_id: String, content: String) -> void:
	_send_fire_and_forget("chat.send", {"channel_id": channel_id, "content": content})

func leave_chat(channel_id: String) -> void:
	_send("chat.leave", {"channel_id": channel_id})

# DM
func send_dm(recipient_id: String, content: String) -> void:
	_send("dm.send", {"recipient_id": recipient_id, "content": content})

# Presence
func update_presence(status: String = "online") -> void:
	_send("presence.update", {"status": status})

# Voting
func cast_vote(vote_id: String, option_id) -> void:
	_send("vote.cast", {"vote_id": vote_id, "option_id": option_id})

func cast_veto(vote_id: String) -> void:
	_send("vote.veto", {"vote_id": vote_id})

# World
# has_capacity is a bool, not a String: the backend filter validator accepts
# only a JSON boolean and rejects the whole request with
# "invalid_has_capacity_filter" otherwise. Only sent when true, matching the
# backend default (false means "do not filter").
func world_list(mode: String = "", has_capacity: bool = false) -> void:
	var payload := {}
	if mode != "":
		payload["mode"] = mode
	if has_capacity:
		payload["has_capacity"] = true
	_send("world.list", payload)

func world_create(mode: String) -> void:
	_send("world.create", {"mode": mode})

func world_find_or_create(mode: String) -> void:
	_send("world.find_or_create", {"mode": mode})

# Mirrors join_match: `ctx` is the optional join context, passed to the game
# module untouched and bounded by the same limits.
func world_join(world_id: String, ctx: Dictionary = {}) -> void:
	var payload := {"world_id": world_id}
	if not ctx.is_empty():
		payload["ctx"] = ctx
	_send("world.join", payload)

func world_leave() -> void:
	_send("world.leave", {})

## Send an input frame to the world you are in.
##
## Pass `seq` - a per-input sequence number your client increments - to opt into
## world.ack reconciliation; the server reports the highest seq it has consumed
## via the `world_ack` signal. `seq` rides as a top-level sibling of `payload` on
## the wire, never nested inside it, and only when `seq >= 0`, so `seq` 0 is a
## real value. Omit it to send unsequenced input, which stamps no seq on the
## frame and gets no ack.
##
## The server accepts 0 to 2^53 - 1. Outside that range the seq is ignored, not
## the input: the input is still queued and applied to the world as normal, only
## the acknowledgement skips it. GDScript ints are 64-bit and reach far higher,
## so count up from 0 rather than seeding the counter from a timestamp.
func world_input(data: Dictionary, seq: int = -1) -> void:
	_send_fire_and_forget("world.input", data, seq)

# Session
func send_heartbeat() -> void:
	_send_fire_and_forget("session.heartbeat", {})

func _send(type: String, payload: Dictionary) -> String:
	_cid_counter += 1
	var cid := str(_cid_counter)
	var msg := JSON.stringify({"type": type, "payload": payload, "cid": cid})
	_socket.send_text(msg)
	return cid

## Call an extension's RPC method. Returns the `cid` the reply will carry.
##
## Named for the wire frame it sends, because `rpc` itself belongs to Godot:
## `Node.rpc(StringName, ...)` is the engine's own multiplayer call and
## shadowing it is a parse error.
##
##     var cid := realtime.rpc_call("quests.claim", {"quest_key": "daily"})
##     realtime.rpc_ok.connect(func(reply_cid, result):
##         if reply_cid == cid: ...)
##
## Or, since `on_reply` is usually what you want:
##
##     realtime.rpc_call("quests.claim", {"quest_key": "daily"},
##         func(ok, data): ...)
##
## `on_reply` is called once with `(ok: bool, data: Dictionary)` - the result
## object when `ok`, the error object when not. `params` and `result` are
## always dictionaries, so either can grow a field without breaking a shipped
## game.
func rpc_call(method: String, params: Dictionary = {}, on_reply: Callable = Callable()) -> String:
	var cid := _send("rpc.call", {"protocol": 1, "method": method, "params": params})
	if on_reply.is_valid():
		_pending[cid] = on_reply
	return cid

func _send_fire_and_forget(type: String, payload: Dictionary, seq: int = -1) -> void:
	var frame := {"type": type, "payload": payload}
	# seq rides as a top-level sibling of payload, never nested, and only when
	# the caller opts in. >= 0 so seq 0 is stamped as a real value; -1 = unset.
	if seq >= 0:
		frame["seq"] = seq
	var msg := JSON.stringify(frame)
	_socket.send_text(msg)

## Dictionary.get(key, default) only returns the default when key is
## absent, not when it's present-but-null or a non-string. A typed signal
## emit crashes with "Cannot convert argument from Nil/int/... to String"
## on either case and the handler never runs - the worst outcome for a
## signal whose whole purpose is surfacing a diagnostic. Coerce instead.
func _as_text(value: Variant) -> String:
	return "" if value == null else str(value)

func _handle_rpc_reply(type: String, cid: String, payload: Dictionary) -> void:
	var ok := type == "rpc.ok"
	var data: Dictionary = payload.get("result", {}) if ok else payload.get("error", {})
	if not data is Dictionary:
		data = {}
	# An error object with nothing in it still has to carry a code, or a
	# caller branching on `code` gets an empty string and no way to tell a
	# server defect from a domain outcome.
	if not ok and not data.has("code"):
		data["code"] = "internal"
	if _pending.has(cid):
		var on_reply: Callable = _pending[cid]
		_pending.erase(cid)
		if on_reply.is_valid():
			on_reply.call(ok, data)
	if ok:
		rpc_ok.emit(cid, data)
	else:
		rpc_error.emit(cid, data)

func _handle_message(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if parsed == null or not parsed is Dictionary:
		return

	var msg: Dictionary = parsed
	var type: String = msg.get("type", "")
	var payload: Dictionary = msg.get("payload", {})

	# Correlated replies never reach the dispatch table: they belong to one
	# call, not to every listener. `_pending` was declared and never populated
	# before rpc() existed, so a cid was minted for every send and read by
	# nobody.
	if type == "rpc.ok" or type == "rpc.error":
		_handle_rpc_reply(type, msg.get("cid", ""), payload)
		return

	match type:
		# Session
		"session.connected":
			connected.emit()
		"session.heartbeat":
			heartbeat.emit(payload)
		# Match
		"match.matched":
			match_matched.emit(payload)
		"match.joined":
			match_joined.emit(payload)
		"match.left":
			match_left.emit(payload)
		"match.state":
			match_state.emit(payload)
		"match.finished":
			match_finished.emit(payload)
		"match.list":
			match_list_received.emit(payload)
		"match.matchmaker_expired":
			matchmaker_expired.emit(payload)
		"match.matchmaker_failed":
			matchmaker_failed.emit(payload)
		# Chat
		"chat.message":
			chat_message.emit(payload)
		"chat.joined":
			chat_joined.emit(payload)
		"chat.left":
			chat_left.emit(payload)
		# DM
		"dm.message":
			dm_message.emit(payload)
		"dm.sent":
			dm_sent.emit(payload)
		# Notifications
		"notification.new":
			notification_received.emit(payload)
		# Matchmaker
		"matchmaker.queued":
			matchmaker_queued.emit(payload)
		"matchmaker.removed":
			matchmaker_removed.emit(payload)
		# Presence
		"presence.updated":
			presence_updated.emit(payload)
		# Voting acks
		"vote.cast_ok":
			vote_cast_ok.emit(payload)
		"vote.veto_ok":
			vote_veto_ok.emit(payload)
		# Voting lifecycle (asobi broadcasts these prefixed as match.vote_*)
		"match.vote_start":
			vote_start.emit(payload)
		"match.vote_tally":
			vote_tally.emit(payload)
		"match.vote_result":
			vote_result.emit(payload)
		"match.vote_vetoed":
			vote_vetoed.emit(payload)
		# World
		"world.joined":
			world_joined.emit(payload)
		"world.left":
			world_left.emit(payload)
		"world.tick":
			world_tick.emit(payload)
		"world.terrain":
			var coords_arr: Array = payload.get("coords", [0, 0])
			var coords := Vector2i(int(coords_arr[0]), int(coords_arr[1])) if coords_arr.size() >= 2 else Vector2i.ZERO
			var data: String = _as_text(payload.get("data"))
			world_terrain.emit(coords, data)
		"world.list":
			world_list_received.emit(payload)
		"world.phase_changed":
			world_phase_changed.emit(payload)
		"world.finished":
			world_finished.emit(payload)
		# Explicit arm: reclaim world.ack from the generic world.* passthrough
		# below, where it would otherwise surface as world_event("ack", ...).
		"world.ack":
			world_ack.emit(payload)
		# Errors
		"error":
			var reason: String = payload.get("reason", "")
			if reason == "session_revoked" or reason == "invalid_token":
				_revoked = true
				session_revoked.emit()
			error_received.emit(payload)
		# Dev diagnostics
		"game.error", "module.error":
			game_error.emit(
				_as_text(payload.get("callback")),
				_as_text(payload.get("script")),
				_as_text(payload.get("message"))
			)
		# Production game.send(player_id, message) push.
		"game.message", "module.message":
			game_message.emit(payload)
		# Named push from an extension: payload.module/event/data.
		"module.event":
			module_event.emit(payload)
		_:
			# Handle dynamic match/world events
			if type.begins_with("match."):
				match_event.emit(type.substr(6), payload)
			elif type.begins_with("world."):
				world_event.emit(type.substr(6), payload)
