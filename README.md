# asobi-godot

Godot 4.x client SDK for the [Asobi](https://github.com/widgrensit/asobi) game backend. Tested on Godot 4.4 LTS and Godot 4.5.

## Installation

1. Copy `addons/asobi/` from this repo into your project's `addons/` folder, **or** clone as a git submodule:

   ```bash
   git submodule add https://github.com/widgrensit/asobi-godot.git vendor/asobi-godot
   ln -s ../vendor/asobi-godot/addons/asobi addons/asobi
   ```

   For a tagged release (recommended):

   ```bash
   git submodule add -b v0.6.1 https://github.com/widgrensit/asobi-godot.git vendor/asobi-godot
   ```

2. *Project → Project Settings → Plugins* and tick **Asobi**. Reload the project so Godot picks up the autoload.

   The plugin auto-registers an `Asobi` autoload singleton — you do **not** need to add an `AsobiClient` node to your scene.

## Run a backend first

The SDK talks to an Asobi server. The fastest way to get one is:

```bash
git clone https://github.com/widgrensit/sdk_demo_backend
cd sdk_demo_backend && docker compose up -d
```

That serves at `http://localhost:8084` (HTTP + WebSocket on `/ws`) with a 2-player `demo` mode. For the full reference game (arena shooter) see [`asobi_arena_lua`](https://github.com/widgrensit/asobi_arena_lua).

## Quick Start

Use the `Asobi` autoload directly from any script:

```gdscript
func _ready() -> void:
    Asobi.host = "localhost"
    Asobi.port = 8084

    var resp := await Asobi.auth.login("player1", "secret123")
    if resp.has("error"):
        push_error("Login failed: %s" % resp.error)
        return

    # A formed match arrives as match_matched; match.joined is the reply to
    # a client-initiated match.join. Both mean "in a match -- match.state
    # will follow." Listen for match_matched and join.
    Asobi.realtime.match_matched.connect(_on_matched)
    Asobi.realtime.match_state.connect(_on_state)

    Asobi.realtime.connect_to_server()
    Asobi.realtime.add_to_matchmaker("demo")

func _on_matched(payload: Dictionary) -> void:
    Asobi.realtime.join_match(payload["match_id"])

func _on_state(payload: Dictionary) -> void:
    var players: Dictionary = payload.get("players", {})
    print("Tick %s, %d players" % [payload.get("tick", 0), players.size()])
```

A complete worked example lives at `example/example_usage.gd`. A runnable demo (player vs. player + bots) is at [asobi-godot-demo](https://github.com/widgrensit/asobi-godot-demo).

### Guest / anonymous auth

Sign a player in with no username or password. A guest is a real player (with a persistent `player_id`); the device holds a `{device_id, device_secret}` keypair and the same pair resumes the same player on every launch.

#### Guest device (recommended)

`guest_device` manages the keypair for you - it generates a standard-base64 secret from a CSPRNG on first run, persists it to `user://`, reuses it after, and signs in:

```gdscript
var resp := await Asobi.auth.guest_device()
if resp.has("error"):
    push_error("Guest sign-in failed: %s" % resp.error)
    return
if resp.get("created", false):
    print("brand-new guest: %s" % resp.player_id)  # run first-time onboarding
else:
    print("welcome back: %s" % resp.player_id)
```

Options (all optional) let you choose where the pair is stored or plug in your own byte source:

```gdscript
await Asobi.auth.guest_device({
    "path": "user://mygame_device.json",     # default user://asobi_device.json
    "random_bytes": func(n): return my_source(n),  # Callable(int) -> PackedByteArray
})
```

Erase the stored pair to switch account or honour a "forget me" / delete-my-data request. The next `guest_device` mints a brand-new guest (`created = true`). This is local-only - pair it with `logout` to end the current session, or `upgrade_guest` first if the player wants to keep the guest:

```gdscript
await Asobi.auth.logout()
AsobiDevice.clear()  # pass the same path/store opts you signed in with
```

#### Bring your own credentials

If you'd rather manage the keypair yourself (e.g. an OS keychain), call `guest` directly. `device_secret` must be **standard** base64 (RFC 4648, `+/` with `=` padding) of >= 32 CSPRNG bytes, or the server rejects it as `weak_device_secret`; `device_id` is any stable per-install id:

```gdscript
# One time: create and store a device secret, e.g.
#   var bytes := Crypto.new().generate_random_bytes(32)
#   var device_secret := Marshalls.raw_to_base64(bytes)
var resp := await Asobi.auth.guest(device_id, device_secret)
if resp.has("error"):
    push_error("Guest sign-in failed: %s" % resp.error)
```

#### Upgrade to a permanent account

Convert a guest into a real account (keeps the same `player_id`, so no progress is lost):

```gdscript
var upgraded := await Asobi.auth.upgrade_guest("player1", "secret123")
if upgraded.has("error"):
    push_error("Upgrade failed: %s" % upgraded.error)
```

All of these store the returned tokens exactly like `login`, so the player stays signed in.

## Features

- **Auth** - Register, login, guest / anonymous, token refresh
- **Players** - Profiles, updates
- **Matchmaker** - Queue, status, cancel
- **Matches** - List, details
- **Leaderboards** - Top scores, around player, submit
- **Economy** - Wallets, store, purchases
- **Inventory** - Items, consume
- **Social** - Friends, groups, chat history
- **Tournaments** - List, join
- **Notifications** - List, read, delete
- **Storage** - Cloud saves, generic key-value
- **Realtime** - WebSocket with signals for matches, chat, presence, matchmaking

See the [WebSocket protocol guide](https://github.com/widgrensit/asobi/blob/main/guides/websocket-protocol.md) for the full event surface.

## License

Apache-2.0
