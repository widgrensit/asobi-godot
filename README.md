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

Erase the stored pair to switch account. The next `guest_device` mints a brand-new guest (`created = true`). This is local-only - pair it with `logout` to end the current session, or `upgrade_guest` first if the player wants to keep the guest:

```gdscript
await Asobi.auth.logout()
AsobiDevice.clear()  # pass the same path/store opts you signed in with
```

#### Deleting the account

Clearing the pair does **not** delete anything on the server - the account and its data are still there, just unreachable from this device. For an actual "delete my data" request, erase the account:

```gdscript
await Asobi.players.erase_self()                  # guest or provider-only account
await Asobi.players.erase_self("secret123")       # account with a password
```

Irreversible: the player and everything the server holds for it go. Pass the password only for an account that has one - a guest has no credential to re-present, so its session is the confirmation. A wrong password comes back as `{"code": "player.confirmation_failed", "status_code": 403}` and changes nothing.

On success the local session is cleared, because the server deleted the token pair in the same transaction. Anything afterwards on that session is a `401`; for a retried erase, read that as "it already worked".

Needs a server carrying `POST /api/v1/players/me/erase`; older ones answer `404`.

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

#### Testing with two clients on one machine

The saved pair identifies the machine, so two instances of the same project sign in as the same player: matchmaking will not pair them and their views drift. In a dev build, skip persistence and mint a throwaway guest per launch instead:

```gdscript
var creds := AsobiDevice.generate()
var resp := await Asobi.auth.guest(creds["device_id"], creds["device_secret"])
```

For stable test players, open Debug > Customize Run Instances..., give each instance a `-- player=N` launch argument, and pass `{"path": "user://asobi_device_%s.json" % slot}` to `guest_device`. Full recipe, plus why two players can still land in separate matches: [Testing with multiple players](https://github.com/widgrensit/asobi/blob/main/guides/testing-multiple-players.md).

## Worlds and client-side prediction

Worlds are server-ticked sessions you join over the socket:

```gdscript
Asobi.realtime.world_tick.connect(_on_tick)
Asobi.realtime.world_join(world_id)
Asobi.realtime.world_input({"move_x": 1})
```

World signals: `world_joined`, `world_left`, `world_tick`, `world_terrain(coords, data)`, `world_list_received`, `world_phase_changed`, `world_finished`, `world_ack`, and `world_event(event_name, payload)` for anything else the game module pushes.

`world_tick` carries deltas, not a snapshot:

```json
{"type": "world.tick", "payload": {"tick": 42, "updates": [{"op": "u", "id": "e1", "x": 3}]}}
```

`op` is `a` (added, with the entity's full state), `u` (updated, only the fields that changed) or `r` (removed). A full `op: "a"` snapshot of a zone's entities arrives on every fresh subscription to that zone, not once per zone per session. Joining subscribes your whole interest ring, so it delivers one snapshot frame per loaded, non-empty zone in the ring, not one frame overall. A zone holding no entities sends no entity snapshot, but it still pushes its terrain chunk if the world has a terrain provider, so you get `world_terrain` from it and no `world_tick`.

Crossing a boundary delivers fresh snapshots too. The crossing recomputes the ring and subscribes the band of zones that just entered it, and each of those replays a full snapshot: at the default `view_radius` of 1 your ring is the 3x3 block around you, and an orthogonal step keeps 6 of the 9 zones and brings in 3 new ones. Only the destination zone is a no-op, because at radius 1 it was already in the old ring. Do not generalise that no-op to the crossing as a whole. Zones that dropped out of the ring are unsubscribed and send `op: "r"` for each of their entities, and walking back re-subscribes them for another full snapshot - a player oscillating across a boundary re-snapshots every time.

Between snapshots a frame mentions an entity solely when something about it changed. Zones are not on independent schedules: one ticker per world fans a single tick number out to every zone, and `broadcast_interval` (default 3) is one world-level value, so every subscribed zone broadcasts on the same tick and the several frames land together. A zone where nothing changed sends no frame at all. Fold each frame into your own entity map - do not treat one frame as the world. `op` and `id` are wire metadata, so keep them out of the state you accumulate.

### Predicted input and `world_ack`

`world_input(data: Dictionary, seq: int = -1)` takes a sequence number as its optional second argument. Stamp each input with your own increasing `seq` and the server answers with `world.ack`, carrying a `seq` it has consumed as of `tick`:

```json
{"type": "world.input", "seq": 412, "payload": {"move_x": 1}}
{"type": "world.ack", "payload": {"tick": 42, "seq": 412}}
```

`seq` rides as a top-level sibling of `payload`, never nested inside it. The ack arrives as `world_ack(payload)`. `JSON.parse_string` decodes every JSON number as a float, so `payload.tick` and `payload.seq` reach the handler as `42.0` and `412.0` (`TYPE_FLOAT`), not ints - cast with `int()` before comparing them against anything you hold.

The ack is per zone, not per connection: each subscribed zone keeps its own record of your highest consumed `seq` and acks from it, and nothing in the frame says which zone sent it. Once you have crossed a boundary and stamped an input on the far side, every subscribed zone holding a record for you is acking, and because they all broadcast on the same tick those acks arrive together, in no defined order. Only the zone you are in advances its record; the one you left keeps repeating the mark it froze when you were there, so `payload.seq` can go backwards from one ack to the next. Your own counter never goes backwards; what you receive does. Known wart, tracked as [widgrensit/asobi#477](https://github.com/widgrensit/asobi/issues/477).

Reconciliation is yours to write, and it must keep a running maximum: ignore any ack whose `seq` does not exceed the highest you have already accepted. Only then drop the buffered inputs up to that `seq` and replay the rest on top of the state you have accumulated from `world_tick`. Pruning against a stale ack re-applies inputs the server has already consumed. `_apply_input` and `_reset_to_server` below are stubs for you to fill in - they are the game-specific half, and everything else runs as pasted.

```gdscript
var _seq := 0
var _acked := -1
var _predicted: Array[Dictionary] = []
var _entities: Dictionary = {}

func _ready() -> void:
    Asobi.realtime.world_ack.connect(_on_ack)
    Asobi.realtime.world_tick.connect(_on_tick)

func send_input(data: Dictionary) -> void:
    _seq += 1
    _predicted.append({"seq": _seq, "data": data})
    Asobi.realtime.world_input(data, _seq)
    _apply_input(data)

func _on_tick(payload: Dictionary) -> void:
    for update in payload.get("updates", []):
        var id: String = str(update.get("id", ""))
        match update.get("op", ""):
            "a":
                _entities[id] = _fields(update)
            "u":
                if _entities.has(id):
                    _entities[id].merge(_fields(update), true)
            "r":
                _entities.erase(id)

# A zone you have left keeps acking its own frozen mark, so an ack that does
# not beat the running maximum is stale and must not prune anything.
func _on_ack(payload: Dictionary) -> void:
    var acked := int(payload["seq"])
    if acked <= _acked:
        return
    _acked = acked
    while not _predicted.is_empty() and _predicted[0]["seq"] <= acked:
        _predicted.pop_front()
    _reset_to_server(_entities)
    for input in _predicted:
        _apply_input(input["data"])

# Drop the wire metadata: merging `op` into accumulated state would rewrite it
# on every delta, and `id` is already the key.
func _fields(update: Dictionary) -> Dictionary:
    var out := update.duplicate()
    out.erase("op")
    out.erase("id")
    return out

# Yours: apply one input to your local player.
func _apply_input(data: Dictionary) -> void:
    pass

# Yours: snap your local player back onto the authoritative state, so the
# replay above starts from what the server confirmed.
func _reset_to_server(entities: Dictionary) -> void:
    pass
```

- Opt-in: the server acks only players that stamped a `seq`. Connect to `world_ack` but never pass one and nothing ever arrives, with no error.
- Each ack is a high-water mark, not a receipt per input - one `seq`, the highest that zone has consumed as of `tick`. Once a zone holds one for you it repeats it on every broadcast tick, so the same `seq` arriving again, with a later `tick`, is normal and means nothing new was consumed. Acks are addressed to you alone and never ride on the shared `world.tick` broadcast.
- Acks come from each subscribed zone separately, so after a crossing a batch of them lands on the same broadcast tick with their `seq` values in no defined order. Keep the running maximum the sample keeps ([widgrensit/asobi#477](https://github.com/widgrensit/asobi/issues/477)).
- A rejected input still advances the ack, so a dropped input cannot strand the client.
- Prune and replay in the ack handler, not the tick handler. When a zone's broadcast produced deltas it sends `world.tick` first and its `world.ack` second, so a replay driven off the tick has not seen the new ack yet and re-applies inputs the server has already consumed. When nothing changed there is no `world.tick` at all and the ack arrives alone, which a tick-driven replay misses entirely.
- The `-1` default means unsequenced. Only `seq >= 0` is stamped, and `seq` 0 is a real value, so a counter starting at 0 is fine.
- The server accepts `0 <= seq <= 2^53 - 1`. Outside that range the `seq` is ignored, not the input: the input is still queued and applied to the world exactly as normal, and only the acknowledgement skips it. Nor does the ack stream stop - if a valid `seq` was recorded earlier, acks keep arriving with that old high-water mark, they simply stop advancing. GDScript ints are 64-bit and reach far higher, so a counter seeded from a nanosecond timestamp never advances the ack; count up from 0.
- `broadcast_interval` is one world-level value, not a per-zone one. Set it to 1 in the world mode config for an ack on every simulation tick from every zone that holds a `seq` for you; the default is 3. See [world server](https://asobi.dev/docs/world-server).
- Needs an asobi server >= v0.84.0; older ones never send `world.ack`, and that silence is not an error.
- Needs this addon >= v0.18.0; earlier versions have no `world_ack` signal to connect to and no `seq` argument on `world_input`.

Frame reference: [client-side prediction](https://asobi.dev/docs/protocols/websocket#client-side-prediction).

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
- **Realtime** - WebSocket with signals for matches, worlds, chat, presence, matchmaking

See the [WebSocket protocol guide](https://github.com/widgrensit/asobi/blob/main/guides/websocket-protocol.md) for the full event surface.

## License

Apache-2.0
