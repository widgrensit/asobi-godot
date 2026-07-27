extends Node

# Guest / anonymous auth example.
#
# A guest is a real player (with a persistent player_id) that needs no username
# or password. The device holds a {device_id, device_secret} keypair; the same
# pair resumes the same player on every launch. guest_device manages that keypair
# for you (generate on first run, persist, reuse) and signs in.
#
# The plugin registers an `Asobi` autoload singleton, so use it directly - you
# do not need an AsobiClient node in your scene.

func _ready() -> void:
	Asobi.host = "localhost"
	Asobi.port = 8084

	# --- The one-call flow (recommended) --------------------------------
	# Generates + saves the keypair on first run, reuses it after, signs in.
	var resp := await Asobi.auth.guest_device()
	if resp.has("error"):
		push_error("guest sign-in failed: %s" % resp.error)
		return

	# player_id is who you are in the backend - use it for everything.
	if resp.get("created", false):
		print("brand-new guest: %s" % resp.player_id)
		# ... run first-time onboarding here ...
	else:
		print("welcome back, guest: %s" % resp.player_id)

	# You now have an authenticated session. Do backend things:
	await Asobi.leaderboards.submit_score("weekly", 1500)
	Asobi.realtime.connect_to_server()
	Asobi.realtime.add_to_matchmaker("demo")

# --- Turning a guest into a real account --------------------------------
# Call this (after a successful guest sign-in) when the player wants their
# progress to survive a reinstall or move to another device. The player_id is
# KEPT - a username/password is just added to the same player.
func upgrade_to_account(username: String, password: String) -> void:
	var resp := await Asobi.auth.upgrade_guest(username, password)
	if resp.has("error"):
		push_error("upgrade failed: %s" % resp.error)
		return
	print("account claimed, same player_id: %s" % resp.player_id)

# --- Switch guest / "forget me" / delete-my-data ------------------------
# Erase the stored keypair. The NEXT guest_device mints a brand-new guest
# (created = true). This is local-only - it does not delete the server account,
# so pair it with logout to end the current session. If the player wants to KEEP
# the current guest, call upgrade_guest first.
func forget_guest() -> void:
	await Asobi.auth.logout()
	AsobiDevice.clear()  # pass the same path/store opts you signed in with
	print("guest forgotten; next launch starts fresh")

# --- Options: custom storage or a stronger byte source ------------------
# Choose where the pair is stored, or plug in your own source of random bytes.
func _sign_in_with_options() -> void:
	await Asobi.auth.guest_device({
		"path": "user://mygame_device.json",  # default user://asobi_device.json
		"random_bytes": func(n: int) -> PackedByteArray:
			# return exactly n random bytes from your source
			return Crypto.new().generate_random_bytes(n),
	})

# --- Bring your own credentials -----------------------------------------
# If you'd rather manage the keypair yourself (e.g. an OS keychain), skip the
# helper and pass the values to guest() directly. device_secret must be standard
# base64 of >= 32 random bytes; device_id is any stable per-install id.
func _sign_in_manual(device_id: String, device_secret: String) -> void:
	var resp := await Asobi.auth.guest(device_id, device_secret)
	if not resp.has("error"):
		print("signed in: %s" % resp.player_id)
