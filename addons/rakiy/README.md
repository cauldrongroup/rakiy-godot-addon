# Rakiy Godot addon

**This addon is in heavy early development.** API and behavior may change.

Connect your Godot 4 game to the [Rakiy](https://github.com/cauldrongroup/rakiy-godot-addon) relay and lobby service over WebSocket: handshake, send/receive data by peer ID, and create/join/leave/list lobbies. See the [client protocol](https://github.com/cauldrongroup/rakiy-godot-addon/blob/main/protocol.md) for the full contract. **Full documentation:** [Rakiy docs — Godot add-on](https://docs.rakiy.up.railway.app/integrations/godot/).

## Installation

1. Copy the `addons/rakiy` folder into your project's `addons/` directory.
2. Enable the addon: **Project -> Project Settings -> Plugins** and enable "Rakiy" (if you use the optional editor plugin).
3. Add the client as an Autoload: **Project -> Project Settings -> Autoload**, add `RakiyClient` with path `res://addons/rakiy/rakiy_client.gd`.

Alternatively, add a child node with script `res://addons/rakiy/rakiy_client.gd` and call `poll()` from your `_process()`.

## v1.1.0 breaking changes

**Signal renamed:** `connected` is now `websocket_opened`. This signal fires when the WebSocket opens and the handshake is sent, not when the server confirms the handshake. Use `handshake_ok` to know when the connection is ready.

**Debug toggle:** `const DEBUG` is now `@export var debug` (lowercase, default `false`). Toggle it in the inspector or set `RakiyClient.debug = true` in code.

**Handshake timeout:** Both the client and server now enforce a 10-second handshake timeout. If the server does not respond in time, `handshake_fail` is emitted automatically.

**HTML5 / Web export:** The client sends the JSON handshake as soon as the socket is `STATE_OPEN`, including when the browser reports open on the first `poll()` (so the server always receives `{"type":"handshake",...}` within a few hundred ms of connect). `connect_to_url` runs one immediate `poll()` so the first send is not delayed until the next frame.

**Verify in the browser:** Export to Web, open DevTools → **Network** → select the WebSocket → **Messages**. You should see an **outgoing** text frame with `"type":"handshake"` shortly after connect, before any server `handshake_fail`.

## Compact state sync (bandwidth optimization)

For high-frequency player state updates (e.g. 20 Hz position/rotation sync), use `RakiyPack` instead of JSON to reduce bandwidth by ~60% per update.

**Sending:**

```gdscript
const RAKIY_PACK := preload("res://addons/rakiy/rakiy_pack.gd")

var payload := RAKIY_PACK.pack_player_state(position, yaw, pitch)
RakiyClient.send_data(target_peer_id, RakiyConstants.CHANNEL_UNRELIABLE_GAME, false, payload)
```

`send_data` accepts `PackedByteArray` and base64-encodes it automatically.

**Receiving:**

```gdscript
func _on_data_received(peer_id: int, channel: int, reliable: bool, payload: Variant) -> void:
    var data = RAKIY_PACK.unpack_player_state(payload)
    if data.is_empty():
        return
    var pos := Vector3(data.p[0], data.p[1], data.p[2])
    var yaw := float(data.y)
    var pitch := float(data.pitch)
```

`unpack_player_state` handles both the compact binary format and legacy JSON (`{"p":[x,y,z],"y":yaw,"pitch":pitch}`) for backward compatibility.
