class_name AsobiRealtime
extends Node

signal connected
signal disconnected(reason: String)
signal match_state(payload: Dictionary)
signal match_started(payload: Dictionary)
signal match_finished(payload: Dictionary)
signal chat_message(payload: Dictionary)
signal notification_received(payload: Dictionary)
signal matchmaker_matched(payload: Dictionary)
signal presence_changed(payload: Dictionary)
signal error_received(payload: Dictionary)
signal vote_start(payload: Dictionary)
signal vote_tally(payload: Dictionary)
signal vote_result(payload: Dictionary)
signal vote_vetoed(payload: Dictionary)

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

func join_match(match_id: String) -> void:
	_send("match.join", {"match_id": match_id})

func send_match_input(input: Dictionary) -> void:
	_send_fire_and_forget("match.input", input)

func leave_match() -> void:
	_send("match.leave", {})

func add_to_matchmaker(mode: String = "default") -> void:
	_send("matchmaker.add", {"mode": mode})

func remove_from_matchmaker(ticket_id: String) -> void:
	_send("matchmaker.remove", {"ticket_id": ticket_id})

func join_chat(channel_id: String) -> void:
	_send("chat.join", {"channel_id": channel_id})

func send_chat_message(channel_id: String, content: String) -> void:
	_send_fire_and_forget("chat.send", {"channel_id": channel_id, "content": content})

func leave_chat(channel_id: String) -> void:
	_send("chat.leave", {"channel_id": channel_id})

func update_presence(status: String = "online") -> void:
	_send("presence.update", {"status": status})

func cast_vote(vote_id: String, option_id) -> void:
	_send("match.vote_cast", {"vote_id": vote_id, "option_id": option_id})

func cast_veto(vote_id: String) -> void:
	_send("match.vote_veto", {"vote_id": vote_id})

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
		"session.connected":
			connected.emit()
		"match.state":
			match_state.emit(payload)
		"match.started":
			match_started.emit(payload)
		"match.finished":
			match_finished.emit(payload)
		"chat.message":
			chat_message.emit(payload)
		"notification.new":
			notification_received.emit(payload)
		"match.matched":
			matchmaker_matched.emit(payload)
		"presence.changed":
			presence_changed.emit(payload)
		"match.vote_start":
			vote_start.emit(payload)
		"match.vote_tally":
			vote_tally.emit(payload)
		"match.vote_result":
			vote_result.emit(payload)
		"match.vote_vetoed":
			vote_vetoed.emit(payload)
		"error":
			error_received.emit(payload)
