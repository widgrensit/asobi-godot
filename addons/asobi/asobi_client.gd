class_name AsobiClient
extends Node

@export var host: String = "localhost"
@export var port: int = 8080
@export var use_ssl: bool = false

var session_token: String = ""
var player_id: String = ""
var is_authenticated: bool:
	get: return session_token != ""

var http: AsobiHttp
var auth: AsobiAuth
var players: AsobiPlayers
var matchmaker: AsobiMatchmaker
var matches: AsobiMatches
var leaderboards: AsobiLeaderboards
var economy: AsobiEconomy
var inventory: AsobiInventory
var social: AsobiSocial
var tournaments: AsobiTournaments
var notifications: AsobiNotifications
var storage: AsobiStorage
var iap: AsobiIAP
var votes: AsobiVotes
var realtime: AsobiRealtime

var base_url: String:
	get:
		var scheme := "https" if use_ssl else "http"
		return "%s://%s:%d" % [scheme, host, port]

var ws_url: String:
	get:
		var scheme := "wss" if use_ssl else "ws"
		return "%s://%s:%d/ws" % [scheme, host, port]

func _ready() -> void:
	http = AsobiHttp.new()
	add_child(http)

	auth = AsobiAuth.new(self)
	players = AsobiPlayers.new(self)
	matchmaker = AsobiMatchmaker.new(self)
	matches = AsobiMatches.new(self)
	leaderboards = AsobiLeaderboards.new(self)
	economy = AsobiEconomy.new(self)
	inventory = AsobiInventory.new(self)
	social = AsobiSocial.new(self)
	tournaments = AsobiTournaments.new(self)
	notifications = AsobiNotifications.new(self)
	storage = AsobiStorage.new(self)
	iap = AsobiIAP.new(self)
	votes = AsobiVotes.new(self)
	realtime = AsobiRealtime.new(self)
	add_child(realtime)
