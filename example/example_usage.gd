extends Node

# Complete worked example. The plugin registers an `Asobi` autoload singleton,
# so use it directly from any script - you do not need an AsobiClient node in
# your scene.

func _ready() -> void:
	Asobi.host = "localhost"
	Asobi.port = 8084

	# Login
	var auth_resp := await Asobi.auth.login("player1", "secret123")
	if auth_resp.has("error"):
		push_error("Login failed: %s" % auth_resp.error)
		return
	print("Logged in as: %s" % auth_resp.get("username", ""))

	# Get profile
	var player := await Asobi.players.get_self()
	print("Display name: %s" % player.get("display_name", ""))

	# Submit score
	await Asobi.leaderboards.submit_score("weekly", 1500)

	# Connect realtime and queue for a match
	Asobi.realtime.match_matched.connect(_on_matched)
	Asobi.realtime.match_state.connect(_on_state)
	Asobi.realtime.connect_to_server()
	Asobi.realtime.add_to_matchmaker("demo")

func _on_matched(payload: Dictionary) -> void:
	print("Match found: %s" % payload.get("match_id", ""))
	Asobi.realtime.join_match(payload["match_id"])

func _on_state(payload: Dictionary) -> void:
	print("Tick: %s" % str(payload.get("tick", 0)))
