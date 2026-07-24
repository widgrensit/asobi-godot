extends SceneTree

# Device-credential unit test: exercises AsobiDevice generate / load_or_create /
# clear with an injected in-memory store and a deterministic byte source, plus
# AsobiAuth.guest_device forwarding the loaded pair to guest(). No backend.
#
# Run with:
#   godot --headless --path . -s test/test_device.gd

const _AsobiClientScript := preload("res://addons/asobi/asobi_client.gd")
const _AsobiDeviceScript := preload("res://addons/asobi/device.gd")


class MemStore:
	extends RefCounted

	var creds: Dictionary = {}
	var save_calls := 0

	func load_creds() -> Dictionary:
		return creds.duplicate()

	func save_creds(new_creds: Dictionary) -> bool:
		save_calls += 1
		creds = new_creds.duplicate()
		return true

	func clear_creds() -> void:
		creds = {}


class StubHttp:
	extends "res://addons/asobi/asobi_http.gd"

	var last_path := ""
	var last_body := {}
	var response := {}

	func post_request(_client, path: String, body: Dictionary = {}) -> Dictionary:
		last_path = path
		last_body = body
		return response


# Deterministic counter source: distinct bytes per call so a spurious regenerate
# would visibly change the pair, and the secret still decodes to exactly 32.
func _seq_source() -> Callable:
	var state := [0]
	return func(n: int) -> PackedByteArray:
		var out := PackedByteArray()
		for i in range(n):
			out.append((state[0] * 7 + i) % 256)
		state[0] += 1
		return out


var _pass_count := 0
var _fail_count := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	_test_generate_standard_base64()
	_test_generate_custom_id()
	_test_generate_short_source_errors()
	_test_load_or_create_persists_and_resumes()
	_test_clear_erases()
	await _test_guest_device_forwards()

	print("[device] %d passed, %d failed" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)


func _test_generate_standard_base64() -> void:
	var creds := _AsobiDeviceScript.generate({"random_bytes": _seq_source()})
	var secret: String = creds["device_secret"]
	var raw := Marshalls.base64_to_raw(secret)
	_check(raw.size() == 32, "device_secret decodes to exactly 32 bytes")
	_check(Marshalls.raw_to_base64(raw) == secret, "device_secret round-trips through standard base64")
	# Standard base64 uses +/ and = padding, never the url-safe -_ alphabet.
	_check(not secret.contains("-") and not secret.contains("_"), "device_secret uses the standard +/ alphabet")
	_check(creds["device_id"] is String and creds["device_id"] != "", "device_id is a non-empty string")
	_check(creds["device_id"].length() <= 255, "device_id is <= 255 bytes")


func _test_generate_custom_id() -> void:
	var creds := _AsobiDeviceScript.generate({"random_bytes": _seq_source(), "device_id": "my-install-42"})
	_check(creds["device_id"] == "my-install-42", "opts.device_id fixes the id explicitly")


# A custom random_bytes source that under-delivers must fail loud at runtime
# (not via a stripped assert) and never yield a short secret. load_or_create
# propagates the error and does not persist anything.
func _test_generate_short_source_errors() -> void:
	var short_source := func(_n: int) -> PackedByteArray:
		var out := PackedByteArray()
		out.resize(16)
		return out

	var creds := _AsobiDeviceScript.generate({"random_bytes": short_source})
	_check(creds.has("error"), "generate returns an error dict for a short random source")
	_check(not creds.has("device_secret"), "generate yields no secret when the source under-delivers")

	var store := MemStore.new()
	var result := _AsobiDeviceScript.load_or_create({"store": store, "random_bytes": short_source})
	_check(result.has("error"), "load_or_create propagates the short-source error")
	_check(store.save_calls == 0, "load_or_create does not persist a bad pair")


func _test_load_or_create_persists_and_resumes() -> void:
	var store := MemStore.new()
	var opts := {"store": store, "random_bytes": _seq_source()}

	var first := _AsobiDeviceScript.load_or_create(opts)
	_check(store.save_calls == 1, "load_or_create persists on first run")
	_check(_AsobiDeviceScript._valid(first), "first pair is valid")

	var second := _AsobiDeviceScript.load_or_create(opts)
	_check(store.save_calls == 1, "load_or_create does not re-persist when a pair exists")
	_check(second == first, "load_or_create resumes the same pair")


func _test_clear_erases() -> void:
	var store := MemStore.new()
	var opts := {"store": store, "random_bytes": _seq_source()}

	var first := _AsobiDeviceScript.load_or_create(opts)
	_AsobiDeviceScript.clear(opts)
	_check(store.creds.is_empty(), "clear erases the stored pair")

	var minted := _AsobiDeviceScript.load_or_create(opts)
	_check(store.save_calls == 2, "load_or_create mints a fresh pair after clear")
	_check(minted != first, "the post-clear pair differs from the erased one")


func _test_guest_device_forwards() -> void:
	var client: Node = _AsobiClientScript.new()
	root.add_child(client)
	await process_frame
	var stub := StubHttp.new()
	client.http = stub

	var store := MemStore.new()
	var opts := {"store": store, "random_bytes": _seq_source()}
	var creds := _AsobiDeviceScript.generate(opts)
	store.creds = creds.duplicate()

	stub.response = {
		"player_id": "guest-9",
		"access_token": "ga",
		"refresh_token": "gr",
		"created": true
	}
	var resp: Dictionary = await client.auth.guest_device(opts)
	var expected_body := {"device_id": creds["device_id"], "device_secret": creds["device_secret"]}
	_check(stub.last_path == "/api/v1/auth/guest", "guest_device posts to /api/v1/auth/guest")
	_check(stub.last_body == expected_body, "guest_device forwards the loaded pair to guest")
	_check(client.player_id == "guest-9", "guest_device stores the returned player_id")
	_check(resp.get("created") == true, "guest_device passes the raw response through")

	client.clear_persisted_token()
	stub.free()
	client.queue_free()
	await process_frame


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass_count += 1
		print("[device] PASS: ", msg)
	else:
		_fail_count += 1
		printerr("[device] FAIL: ", msg)
