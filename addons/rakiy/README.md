# Rakiy Godot addon

Connect your Godot 4 game to the Rakiy relay and lobby service over WebSocket. **Protocol v2**: compact handshake JSON; game relay and lobby use **binary** frames only. See the monorepo [`multiplayer/protocol.md`](https://github.com/cauldrongroup/rakiy/blob/main/multiplayer/protocol.md) for the full contract.

## Installation

1. Copy the `addons/rakiy` folder into your project's `addons/` directory.
2. Enable the addon: **Project → Project Settings → Plugins** and enable "Rakiy" (if you use the optional editor plugin).
3. Add the client as an Autoload: **Project → Project Settings → Autoload**, add `RakiyClient` with path `res://addons/rakiy/rakiy_client.gd`.

Alternatively, add a child node with script `res://addons/rakiy/rakiy_client.gd` and call `poll()` from your `_process()`.

## Handshake

The client sends `{ "t": "hs", "v": 2, "u": "<username>" }`. Wait for `handshake_ok` before `send_data` or lobby calls.

## Relay and authority

The Rakiy server **only relays** bytes and lists lobbies; it does **not** run your game simulation. **Host authority** (who simulates physics, migration when the host leaves) is **your game’s** responsibility. Use compact snapshots so clients can predict and reconcile.

## Game relay on the wire

Frames use **relay v2** (14-byte header) when payload size is ≤ **65535** bytes; larger frames use **v1** (16-byte header). Both are supported end-to-end.

## Compact state sync

- **Pose**: `RakiyPack.pack_player_state()` (half-float v2, 11 bytes) or `pack_player_states_batch()` (compact batch **0x04**, 10 bytes per entity). Legacy batch **0x03** is still decoded.
- **Physics**: `pack_player_physics_state()` (**0x06**, linear velocity), `pack_player_physics_state_angular()` (**0x07**), or batches `pack_player_states_physics_batch()` / `pack_player_states_physics_angular_batch()`.
- **Merged payloads**: `pack_merged_segments()` / `unpack_merged_segments()` (**0xFE**) to concatenate several `PackedByteArray` blobs into one relay payload (one header on the wire).

Send game data with `send_data(..., RakiyConstants.CHANNEL_UNRELIABLE_GAME, false, payload)` for high-frequency updates, or **`send_lobby_broadcast(...)`** with **`RakiyConstants.TARGET_LOBBY_BROADCAST`** (`0`) so the **server** fans out one upload to every other peer in your lobby (see [`multiplayer/protocol.md`](https://github.com/cauldrongroup/rakiy/blob/main/multiplayer/protocol.md)).

`unpack_player_state` and `unpack_player_states_batch` decode the formats above. Dictionaries may include `v` (linear velocity) and `w` (angular) for physics types.

## Bandwidth and deltas

The relay adds a fixed header per frame (see [protocol](https://github.com/cauldrongroup/rakiy/blob/main/multiplayer/protocol.md)); keep **game payloads** small and binary.

- **Prefer `PackedByteArray`** from `RakiyPack` for gameplay state, not UTF-8 strings.
- **Channels**: high-frequency state on **`CHANNEL_UNRELIABLE_GAME`** (2); chat and critical events on **`CHANNEL_RELIABLE_GAME`** (1).
- **`unreliable_send_rate_cap`**: cap unreliable **WebSocket frames** per window (after bundling; one broadcast = one frame).
- **Automatic bundling**: multiple `PackedByteArray` `send_data` calls to the same `(target, channel, reliable)` in one frame are **queued** and flushed after `poll()` as a single relay payload (one segment = raw bytes; several = `pack_merged_segments` **0xFE**). Incoming **0xFE** payloads are split and **`data_received` is emitted once per segment**. Call **`flush_pending_sends()`** if you drive **`poll()`** without the client node’s `_process`. **String** payloads are not merged with binary; they flush the pending binary queue for that key first.
- **Manual batching**: you can still call `pack_merged_segments()` / `unpack_merged_segments()` yourself.
- **Lobby broadcast**: `send_lobby_broadcast(channel, reliable, payload)` → one uplink frame, server delivers to all lobby peers (deduped).
- **Replication helpers**: `RakiyReplication` (`rakiy_replication.gd`) — `filter_peers_by_interest`, `suggested_sync_interval` for adaptive cadence and relevance.
- **Full snapshots**: `pack_player_state()` / `pack_player_physics_state_angular()` for periodic full snapshots (reliable on unreliable transport, occasional full packets help recover from desync).
- **Selective / delta**: send only fields that changed compared to the last sent state:
  - **Pose** `0x09`: `pack_selective_pose_delta(prev, curr, epsilon)` → `PackedByteArray` (empty if nothing changed — skip `send_data`). If a full v2 frame would be smaller, the helper returns `pack_player_state` instead.
  - **Physics** `0x0A`: `pack_selective_physics_delta(prev, curr, epsilon)` (same rules vs full `0x07`).
  - **Receive**: keep a per-peer `Dictionary` of last known state; on `data_received` with binary payload, use `apply_selective_pose(last_state, payload)` or `apply_selective_physics(last_state, payload)`; for full snapshots use `unpack_player_state` as before.
  - **Inspect wire**: `unpack_selective_pose` / `unpack_selective_physics` return `mask` and decoded fields; `unpack_player_state` also recognizes `0x09` / `0x0A` and returns those inspection dicts.

Example (pose delta over unreliable):

```gdscript
var _last_sent: Dictionary = {}  # same shape as unpack_player_state
var _peer_state: Dictionary = {}  # peer_id -> last applied state (receive path)

func _send_pose_if_changed(target_peer_id: int, state: Dictionary) -> void:
    var delta := RakiyPack.pack_selective_pose_delta(_last_sent, state)
    if delta.is_empty():
        return
    RakiyClient.send_data(
        target_peer_id,
        RakiyConstants.CHANNEL_UNRELIABLE_GAME,
        false,
        delta,
    )
    _last_sent = state.duplicate(true)

func _on_data_received(peer_id: int, _ch: int, _rel: bool, payload: Variant) -> void:
    if payload is PackedByteArray:
        var last: Dictionary = _peer_state.get(peer_id, {})
        _peer_state[peer_id] = RakiyPack.apply_selective_pose(last, payload)
```

## Client options

- **`unreliable_send_rate_cap`** (default `0` = off): max unreliable **game-channel** sends per **`unreliable_send_rate_window_sec`** (default `1.0`) to limit flood / bandwidth spikes.

## Lobbies

- **`lobby_create(name, max_players, metadata, game_id)`** — **`game_id` is required** (non-empty after trim), e.g. `mygame@1.0.0`. Use the **same** string for list and join.
- **`lobby_join(lobby_id, game_id)`** — must match the lobby’s `game_id` or the server rejects with `game mismatch`.

Use `lobby_member_joined` and `lobby_member_left` to maintain the roster; you still receive full `members` on `lobby_created` / `lobby_joined`.

## Demo

The demo lives in `addons/rakiy/demo/` (`main.tscn` uses `demo_main.gd`). It builds a **3D arena** (ground + boundary walls), a **first-person mover** (`fps_player.tscn` / `fps_player.gd`: WASD, Space, mouse look, Esc to free cursor), and **remote peers** as colored capsule meshes (`remote_avatar.tscn`). After you **create or join a lobby**, your pose uses **`RakiyPack` selective deltas**, **`RakiyReplication`** adaptive sync (8–24 Hz) and interest radius, **`send_lobby_broadcast`** when every other member is relevant (otherwise per-peer `send_data`). Open two editor instances or two builds, connect to the same server, join the same lobby, and run around to verify sync.

The left panel still includes connect, lobby, optional text chat, and the compact-binary test checkbox.
