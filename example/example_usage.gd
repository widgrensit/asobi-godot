extends Node

@onready var asobi: AsobiClient = $AsobiClient

func _ready() -> void:
	# Login
	var auth_resp := await asobi.auth.login("player1", "secret123")
	print("Logged in as: %s" % auth_resp.get("username", ""))

	# Get profile
	var player := await asobi.players.get_self()
	print("Display name: %s" % player.get("display_name", ""))

	# Submit score
	await asobi.leaderboards.submit_score("weekly", 1500)

	# Connect realtime
	asobi.realtime.matchmaker_matched.connect(_on_matchmaker_matched)
	asobi.realtime.match_state.connect(_on_match_state)
	asobi.realtime.connect_to_server()
	asobi.realtime.add_to_matchmaker("arena")

func _on_matchmaker_matched(payload: Dictionary) -> void:
	print("Match found: %s" % payload.get("match_id", ""))
	asobi.realtime.join_match(payload["match_id"])

func _on_match_state(payload: Dictionary) -> void:
	print("Tick: %s" % str(payload.get("tick", 0)))
