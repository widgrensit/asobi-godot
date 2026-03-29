# asobi-godot

Godot 4.x client SDK for the [Asobi](https://github.com/widgrensit/asobi) game backend.

## Installation

1. Copy the `addons/asobi/` folder into your project's `addons/` directory
2. Enable the plugin in Project > Project Settings > Plugins

Or add as a git submodule:

```bash
git submodule add https://github.com/widgrensit/asobi-godot.git addons/asobi-godot
```

## Quick Start

Add an `AsobiClient` node to your scene and configure the host/port via the inspector.

```gdscript
@onready var asobi: AsobiClient = $AsobiClient

func _ready() -> void:
    var resp := await asobi.auth.login("player1", "secret123")
    print("Logged in: %s" % resp.get("username", ""))

    # REST APIs
    var player := await asobi.players.get_self()
    var top := await asobi.leaderboards.get_top("weekly")

    # Real-time
    asobi.realtime.match_state.connect(_on_match_state)
    asobi.realtime.connect_to_server()
    asobi.realtime.add_to_matchmaker("arena")

func _on_match_state(payload: Dictionary) -> void:
    print("Tick: %s" % str(payload.get("tick", 0)))
```

## Features

- **Auth** - Register, login, token refresh
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

## License

Apache-2.0
