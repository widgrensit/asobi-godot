extends SceneTree

# Smoke test for asobi-godot against asobi-test-harness.
#
# Exercises the 3 canonical scenarios: auth + WS connect,
# matchmaker → match.matched, match.input → match.state with
# the input applied.
#
# Run with:
#   godot --headless -s smoke_tests/smoke.gd
# Expects ASOBI_URL (default http://localhost:8080) via env var;
# falls back to hardcoded localhost:8080 if unset.

const MATCH_MODE := "smoke"
const STARTUP_TIMEOUT_MS := 60_000
const MATCH_TIMEOUT_MS := 10_000
const STATE_TIMEOUT_MS := 3_000

# Load the client script directly. Using `class_name AsobiClient` would
# require Godot's class cache (editor-built); direct `preload` works in
# headless runs too.
const _AsobiClientScript := preload("res://addons/asobi/asobi_client.gd")

var _result_code: int = 0

func _initialize() -> void:
	_run_test()

func _run_test() -> void:
	var url := _parse_url(OS.get_environment("ASOBI_URL") if OS.has_environment("ASOBI_URL") else "http://localhost:8080")
	_log("Waiting for harness at %s:%d" % [url.host, url.port])
	await _wait_for_server(url)
	_log("Harness reachable.")

	# Two separate clients, one per player.
	var a := await _spawn_player("a", url)
	var b := await _spawn_player("b", url)
	_log("Registered: %s | %s" % [a.player_id, b.player_id])

	# Connect match.matched listeners BEFORE queueing to avoid a race
	# where the server pairs us immediately on queue.
	var matched_a_data := [null]
	var matched_b_data := [null]
	a.realtime.matchmaker_matched.connect(
		func(payload: Dictionary) -> void: matched_a_data[0] = payload,
		CONNECT_ONE_SHOT
	)
	b.realtime.matchmaker_matched.connect(
		func(payload: Dictionary) -> void: matched_b_data[0] = payload,
		CONNECT_ONE_SHOT
	)

	a.realtime.add_to_matchmaker(MATCH_MODE)
	b.realtime.add_to_matchmaker(MATCH_MODE)
	_log("Both queued.")

	await _wait_for_predicate(
		func() -> bool: return matched_a_data[0] != null and matched_b_data[0] != null,
		MATCH_TIMEOUT_MS,
		"match.matched on both players"
	)
	var m_a: Dictionary = matched_a_data[0]
	var m_b: Dictionary = matched_b_data[0]
	_log("Both matched, match_id = %s" % m_a.get("match_id", "?"))

	if m_a.get("match_id") != m_b.get("match_id"):
		_fail("match_id mismatch: %s vs %s" % [m_a.get("match_id"), m_b.get("match_id")])
		return

	# match.input → match.state with input applied.
	var my_x := [-1.0]
	var state_handler := func(payload: Dictionary) -> void:
		var players: Dictionary = payload.get("players", {})
		var me: Variant = players.get(a.player_id)
		if me is Dictionary and me.has("x") and float(me.x) >= 1.0:
			my_x[0] = float(me.x)
	a.realtime.match_state.connect(state_handler)

	a.realtime.send_match_input({"move_x": 1, "move_y": 0})

	await _wait_for_predicate(
		func() -> bool: return my_x[0] >= 1.0,
		STATE_TIMEOUT_MS,
		"match.state with x>=1"
	)
	_log("match.state confirmed: x = %s" % my_x[0])

	a.realtime.disconnect_from_server()
	b.realtime.disconnect_from_server()
	_log("PASS")
	quit(0)

# ---- helpers ----

func _spawn_player(label: String, url: Dictionary) -> Node:
	var client: Node = _AsobiClientScript.new()
	client.host = url.host
	client.port = url.port
	client.use_ssl = url.use_ssl
	root.add_child(client)
	# Wait a frame for _ready to fire on client and its children.
	await process_frame
	await process_frame

	var username := "smoke_%s_%d_%d" % [label, Time.get_ticks_msec(), randi() % 10000]
	var res: Dictionary = await client.auth.register(username, "smoke_pw_12345", username)
	if res.has("error"):
		_fail("register failed for %s: %s" % [label, res])
		return client

	client.realtime.connect_to_server()
	# Give the socket a moment to handshake.
	var connected := [false]
	client.realtime.connected.connect(
		func() -> void: connected[0] = true,
		CONNECT_ONE_SHOT
	)
	await _wait_for_predicate(
		func() -> bool: return connected[0],
		10_000,
		"realtime connect for %s" % label
	)
	return client

func _wait_for_predicate(pred: Callable, timeout_ms: int, what: String) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if pred.call():
			return
		await process_frame
	_fail("timeout waiting for %s" % what)

func _wait_for_server(url: Dictionary) -> void:
	var http := HTTPRequest.new()
	root.add_child(http)
	# HTTPRequest needs a frame tick after being added to the tree
	# before request() is safe to call.
	await process_frame
	var deadline := Time.get_ticks_msec() + STARTUP_TIMEOUT_MS
	var endpoint: String = "%s://%s:%d/api/v1/auth/register" % [
		"https" if url.use_ssl else "http", url.host, url.port
	]
	while Time.get_ticks_msec() < deadline:
		var err := http.request(endpoint, [], HTTPClient.METHOD_GET)
		if err == OK:
			var result: Array = await http.request_completed
			var code: int = int(result[1])
			if code > 0 and code < 500:
				http.queue_free()
				return
		await _sleep_ms(1000)
	http.queue_free()
	_fail("harness never became reachable at %s" % endpoint)

func _sleep_ms(ms: int) -> void:
	var timer := root.create_tween()
	await timer.tween_callback(func() -> void: pass).set_delay(ms / 1000.0).finished

func _parse_url(raw: String) -> Dictionary:
	var use_ssl := raw.begins_with("https://")
	var stripped := raw.replace("http://", "").replace("https://", "").replace("/", "")
	var parts := stripped.split(":")
	return {
		"host": parts[0],
		"port": int(parts[1]) if parts.size() > 1 else (443 if use_ssl else 80),
		"use_ssl": use_ssl
	}

func _log(msg: String) -> void:
	printerr("[smoke] ", msg)

func _fail(msg: String) -> void:
	printerr("[smoke] FAIL: ", msg)
	_result_code = 1
	quit(1)
