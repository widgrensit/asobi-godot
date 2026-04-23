class_name AsobiRealtime
extends Node

signal connected
signal disconnected(reason: String)
signal match_joined(payload: Dictionary)
signal match_left(payload: Dictionary)
signal match_state(payload: Dictionary)
signal match_started(payload: Dictionary)
signal match_finished(payload: Dictionary)
signal match_event(event_name: String, payload: Dictionary)
signal chat_message(payload: Dictionary)
signal chat_joined(payload: Dictionary)
signal chat_left(payload: Dictionary)
signal dm_message(payload: Dictionary)
signal dm_sent(payload: Dictionary)
signal notification_received(payload: Dictionary)
signal matchmaker_queued(payload: Dictionary)
signal matchmaker_matched(payload: Dictionary)
signal matchmaker_removed(payload: Dictionary)
signal presence_updated(payload: Dictionary)
signal presence_changed(payload: Dictionary)
signal error_received(payload: Dictionary)
signal vote_cast_ok(payload: Dictionary)
signal vote_veto_ok(payload: Dictionary)
signal vote_start(payload: Dictionary)
signal vote_tally(payload: Dictionary)
signal vote_result(payload: Dictionary)
signal vote_vetoed(payload: Dictionary)
signal world_joined(payload: Dictionary)
signal world_left(payload: Dictionary)
signal world_tick(payload: Dictionary)
signal world_terrain(coords: Vector2i, data: String)
signal world_list_received(payload: Dictionary)
signal world_event(event_name: String, payload: Dictionary)

var _client: AsobiClient
var _socket := WebSocketPeer.new()
var _is_connected := false
var _is_connecting := false
var _cid_counter := 0
var _pending: Dictionary = {}

func _init(client: AsobiClient) -> void:
	_client = client

func _process(_delta: float) -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		if _is_connected:
			_is_connected = false
			_is_connecting = false
			disconnected.emit("closed")
		return

	_socket.poll()

	if _is_connecting and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_is_connecting = false
		_is_connected = true
		_send("session.connect", {"token": _client.session_token})

	while _socket.get_available_packet_count() > 0:
		var data := _socket.get_packet().get_string_from_utf8()
		_handle_message(data)

func connect_to_server() -> void:
	if _is_connected or _is_connecting:
		return
	var err := _socket.connect_to_url(_client.ws_url)
	if err != OK:
		push_error("Asobi WebSocket connect failed: %d" % err)
		return
	_is_connecting = true

func disconnect_from_server() -> void:
	_socket.close()
	_is_connected = false
	_pending.clear()

# Match
func join_match(match_id: String) -> void:
	_send("match.join", {"match_id": match_id})

func send_match_input(input: Dictionary) -> void:
	_send_fire_and_forget("match.input", input)

func leave_match() -> void:
	_send("match.leave", {})

# Matchmaker
func add_to_matchmaker(mode: String = "default", properties: Dictionary = {}, party: Array = []) -> void:
	var payload := {"mode": mode}
	if not properties.is_empty():
		payload["properties"] = properties
	if not party.is_empty():
		payload["party"] = party
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
func world_list(mode: String = "", has_capacity: String = "") -> void:
	var payload := {}
	if mode != "":
		payload["mode"] = mode
	if has_capacity != "":
		payload["has_capacity"] = has_capacity
	_send("world.list", payload)

func world_create(mode: String) -> void:
	_send("world.create", {"mode": mode})

func world_find_or_create(mode: String) -> void:
	_send("world.find_or_create", {"mode": mode})

func world_join(world_id: String) -> void:
	_send("world.join", {"world_id": world_id})

func world_leave() -> void:
	_send("world.leave", {})

func world_input(data: Dictionary) -> void:
	_send_fire_and_forget("world.input", data)

# Session
func send_heartbeat() -> void:
	_send_fire_and_forget("session.heartbeat", {})

func _send(type: String, payload: Dictionary) -> void:
	_cid_counter += 1
	var cid := str(_cid_counter)
	var msg := JSON.stringify({"type": type, "payload": payload, "cid": cid})
	_socket.send_text(msg)

func _send_fire_and_forget(type: String, payload: Dictionary) -> void:
	var msg := JSON.stringify({"type": type, "payload": payload})
	_socket.send_text(msg)

func _handle_message(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if parsed == null or not parsed is Dictionary:
		return

	var msg: Dictionary = parsed
	var type: String = msg.get("type", "")
	var payload: Dictionary = msg.get("payload", {})

	match type:
		# Session
		"session.connected":
			connected.emit()
		"session.heartbeat":
			pass
		# Match
		"match.joined":
			match_joined.emit(payload)
		"match.left":
			match_left.emit(payload)
		"match.state":
			match_state.emit(payload)
		"match.started":
			match_started.emit(payload)
		"match.finished":
			match_finished.emit(payload)
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
		"matchmaker.matched":
			matchmaker_matched.emit(payload)
		"matchmaker.removed":
			matchmaker_removed.emit(payload)
		# Presence
		"presence.updated":
			presence_updated.emit(payload)
		"presence.changed":
			presence_changed.emit(payload)
		# Voting
		"vote.cast_ok":
			vote_cast_ok.emit(payload)
		"vote.veto_ok":
			vote_veto_ok.emit(payload)
		"vote.start":
			vote_start.emit(payload)
		"vote.tally":
			vote_tally.emit(payload)
		"vote.result":
			vote_result.emit(payload)
		"vote.vetoed":
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
			var data: String = payload.get("data", "")
			world_terrain.emit(coords, data)
		"world.list":
			world_list_received.emit(payload)
		# Errors
		"error":
			error_received.emit(payload)
		_:
			# Handle dynamic match/world events
			if type.begins_with("match."):
				match_event.emit(type.substr(6), payload)
			elif type.begins_with("world."):
				world_event.emit(type.substr(6), payload)
