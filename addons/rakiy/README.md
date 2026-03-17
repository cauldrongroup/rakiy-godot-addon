# Rakiy Godot addon

Connect your Godot 4 game to the [Rakiy](https://github.com/rakiy/rakiy) relay and lobby service over WebSocket: handshake, send/receive data by peer ID, and create/join/leave/list lobbies. See the [client protocol](https://github.com/rakiy/rakiy/blob/main/protocol.md) for the full contract.

## Installation

1. Copy the `addons/rakiy` folder into your project's `addons/` directory.
2. Enable the addon: **Project → Project Settings → Plugins** and enable "Rakiy" (if you use the optional editor plugin).
3. Add the client as an Autoload: **Project → Project Settings → Autoload**, add `RakiyClient` with path `res://addons/rakiy/rakiy_client.gd`.

Alternatively, add a child node with script `res://addons/rakiy/rakiy_client.gd` and call `poll()` from your `_process()`.

**Debug logging**: The client script has a `DEBUG` constant (default `true`). When enabled, connection, handshake, and message events are printed to the Godot output with the `[Rakiy]` prefix. Set `DEBUG := false` in `rakiy_client.gd` to disable.

## Quick start

```gdscript
# After adding RakiyClient as Autoload (name "RakiyClient")
RakiyClient.connect_to_url("ws://127.0.0.1:3000/", "MyPlayer")
# Wait for handshake_ok(peer_id), then use lobby_* or send_data

# Create a lobby
RakiyClient.lobby_create("My game", 4)

# When lobby_created is emitted, use the lobby_id and members (peer_id, username)
# Send data to another peer (use peer_id from members)
RakiyClient.send_data(target_peer_id, RakiyConstants.CHANNEL_RELIABLE_GAME, true, "Hello")
```

Connect signals:

```gdscript
func _ready():
    RakiyClient.handshake_ok.connect(_on_handshake_ok)
    RakiyClient.handshake_fail.connect(_on_handshake_fail)
    RakiyClient.lobby_created.connect(_on_lobby_created)
    RakiyClient.data_received.connect(_on_data_received)

func _on_handshake_ok(peer_id: int):
    print("Connected as peer ", peer_id)

func _on_data_received(peer_id: int, channel: int, reliable: bool, payload: Variant):
    print("From peer %d (ch %d): %s" % [peer_id, channel, payload])
```

## API summary

- **Connection**: `connect_to_url(url, username)`, `disconnect_from_host()`, `poll()` (or rely on node `_process`).  
  **State**: `is_connected_to_host()`, `is_handshaken()`, `get_peer_id()`.
- **Data**: `send_data(target_peer_id, channel, reliable, payload)` — payload is `String` or `PackedByteArray` (sent as base64).
- **Lobby**: `lobby_create(name, max_players, metadata, game_id)`, `lobby_join(lobby_id)`, `lobby_leave(lobby_id)`, `lobby_list(game_id, subscribe)`. Use the same `game_id` for create and list. Use `lobby_list(game_id, true)` to subscribe to live lobby list updates; use the `lobby_members_updated(lobby_id, members)` signal to keep the member list in sync.
- **Signals**: `connected`, `disconnected`, `handshake_ok(peer_id)`, `handshake_fail(reason)`, `data_received(...)`, `lobby_created`, `lobby_joined`, `lobby_left`, `lobby_list_received(lobbies)`, `lobby_members_updated(lobby_id, members)`, `lobby_error(reason)`.

## Useful notes

- **Channels**: Use small integers. Suggested: `RakiyConstants.CHANNEL_CONTROL` (0), `CHANNEL_RELIABLE_GAME` (1), `CHANNEL_UNRELIABLE_GAME` (2). Same semantics as in the [protocol](https://github.com/rakiy/rakiy/blob/main/protocol.md).
- **Reliable vs unreliable**: Use reliable for chat or critical events; use unreliable for high-frequency updates (e.g. positions) where dropping packets is acceptable.
- **wss vs ws**: In production and for HTML5 when your game is on HTTPS, use `wss://`. For local dev use `ws://127.0.0.1:3000/` (or your Rakiy URL). **Godot users**: use `127.0.0.1` instead of `localhost` to avoid a ~20–30s connect delay (engine tries IPv6 first and times out; see [godotengine/godot#67969](https://github.com/godotengine/godot/issues/67969)).
- **Peer IDs**: After `lobby_created` or `lobby_joined`, use the `members` array (each has `peer_id` and `username`). Use `peer_id` as `target_peer_id` in `send_data()`.
- **Multiple games on one server**: Pass a stable `game_id` (e.g. `"my_game_v1"`) to `lobby_create` and `lobby_list`. The lobby selector will only show lobbies for that game.
- **Reactive sync**: Call `lobby_list(game_id, true)` to subscribe; you'll get `lobby_list_received` whenever the list changes. Connect to `lobby_members_updated` and when `lobby_id` is your current lobby, update your member list so it stays in sync when others join or leave.
- **Order**: Send the handshake first (done automatically by `connect_to_url`). Wait for `handshake_ok` before calling `send_data` or lobby methods.
- **Reconnection**: On disconnect, call `connect_to_url` again; you get a new `peer_id`. Re-join lobbies as needed.
- **Self-hosting**: Same protocol; point the URL to your own Rakiy instance (e.g. `ws://127.0.0.1:3000/` or `wss://your-domain/`).

## Running the demo

A full demo is in `addons/rakiy/demo/`. It shows connect, handshake, lobby create/join/leave/list, and send/receive data.

1. Start a Rakiy server locally (`bun run dev` in the Rakiy repo) or use a hosted `wss://` URL.
2. Open this Godot project, set **Main Scene** to `res://addons/rakiy/demo/main.tscn`, then run (F5).
3. Enter URL (e.g. `ws://127.0.0.1:3000/`) and username, click Connect. Create or join a lobby, then send messages.
4. To test with two peers: run the project twice (two game windows) or use another device; have one create a lobby, copy the lobby ID, and the other join with that ID.
