# Rakiy Godot add-on

Godot **4.x** client for the Rakiy multiplayer service: WebSocket relay, lobbies, optional **native P2P** (WebRTC) with signaling on relay channel **65534**.

## Installation

1. Copy **`addons/rakiy`** into your project’s **`addons/`** folder.
2. Enable the plugin: **Project → Project Settings → Plugins** → enable **Rakiy** (needed for the optional WebRTC downloader below).
3. Add **one** Autoload named **`RakiyClient`** pointing at `res://addons/rakiy/rakiy_client.gd`.  
   Do **not** register the same script twice under another name (e.g. a second `Rakiy` autoload) — that creates two WebSocket clients.

## WebRTC (native P2P)

Native **`handshake_capability = "p2p"`** requires **`WebRTCPeerConnection`** (and related types) to exist in the running engine.

- Some **Steam** (and other) Godot builds ship **without** the WebRTC module. Then **`ClassDB.class_exists("WebRTCPeerConnection")`** is false: signaling and data channels will not run; you will see **signaling relay 0/0** and **`webrtc_dc_open=0`** in transport stats.
- Install the official **[webrtc-native](https://github.com/godotengine/webrtc-native)** GDExtension: in the editor, **Project → Tools → Download / update WebRTC native (GitHub latest)**. This unpacks to **`res://addons/webrtc/`** (includes `webrtc.gdextension`). **Restart the editor** after install or update.

Game traffic prefers **WebRTC data channels** when open; see **Send path** below.

## Files

| File | Role |
|------|------|
| `rakiy_client.gd` | WebSocket, handshake (`c`: `relay` / `p2p`), binary relay + lobby parsing, `send_data` P2P routing |
| `rakiy_constants.gd` | Channel IDs, magic numbers, `CHANNEL_SIGNALING` (65534), `TARGET_LOBBY_BROADCAST` (0) |
| `rakiy_p2p.gd` | WebRTC: STUN/TURN, ICE, data channels; lower `peer_id` is the SDP offerer |
| `webrtc_native_installer.gd` | Editor helper used by the plugin to extract the official GDExtension zip |
| `plugin.gd` | Editor: **Project → Tools → Download / update WebRTC native (GitHub latest)** |

## Quick usage

```gdscript
# Web / HTML5 — relay only
RakiyClient.handshake_capability = "relay"
RakiyClient.connect_to_url("wss://your-host/", "Player")

# Native — optional P2P
RakiyClient.handshake_capability = "p2p"
var p2p := RakiyP2P.new()
RakiyClient.set_p2p_helper(p2p)
# Optional TURN
p2p.turn_servers = PackedStringArray(["turn:turn.example.com:3478"])
p2p.turn_username = "user"
p2p.turn_password = "pass"
RakiyClient.connect_to_url("wss://your-host/", "Player")
```

After `handshake_ok`, use `lobby_*` and `send_data` as usual.

### `RakiyP2P` and reconnects

- **`set_p2p_helper(p2p)`** calls **`attach_client`** on the client so lobby signals drive **`_sync_members`**.
- **`disconnect_from_host()`** calls **`reset_peer_sessions()`** on the helper (closes WebRTC peers, clears local state) but **does not** detach the helper from the client. Full teardown (**disconnect signals**, clear client reference) is **`cleanup()`**, used when **replacing** the helper via **`set_p2p_helper`**.
- **`sync_members_from_lobby(members)`** — public; call after lobby state changes if you need to resync (e.g. demo calls this after `set_p2p_helper` and on lobby events).

### Send path (`rakiy_client.send_data`)

- For non-signaling channels, **`send_data`** tries **`RakiyP2P`** first:
  - **`target_peer_id == 0`** ([`TARGET_LOBBY_BROADCAST`](rakiy_constants.gd)) → **`try_send_p2p_all`**: one copy per peer with an **open** data channel (lobby broadcast over P2P is a fan-out, not `peer_id` 0 on the wire).
  - Otherwise → **`try_send_p2p(target_peer_id, …)`**.
- With **`handshake_capability == "p2p"`**, **unreliable game** payloads (**`CHANNEL_UNRELIABLE_GAME`**, not reliable) **do not** fall back to the relay if P2P send is not available yet (frames are dropped until data channels are ready). This avoids a burst of relay traffic during ICE setup. Reliable channels and **`handshake_capability == "relay"`** still use the relay as before.
- **Signaling** (channel **65534**) always uses the Rakiy relay; it is excluded from the P2P game send path above.

### webrtc-native (GDExtension) behavior

The add-on is written for Godot’s built-in WebRTC API and stays compatible with **webrtc-native**:

- **Data channels** may be **`WebRTCLibDataChannel`**: incoming data is read via **`PacketPeer`** (**`get_available_packet_count` / `get_packet`**) in **`RakiyP2P.poll()`**, not the `message_received` signal.
- **Answers:** **`create_answer()`** may be missing on the extension peer connection; the library creates the answer when **`set_remote_description("offer", sdp)`** runs. The add-on only calls **`create_answer()`** if **`has_method("create_answer")`**.

## Transport stats (debug)

**`get_transport_summary()`** on **`RakiyClient`** (used by the demo when debug is on) reports:

- **`webrtc_dc_open`** — count of open WebRTC data channels (via **`RakiyP2P`**).
- **game P2P in/out** — game payloads delivered over data channels (not signaling).
- **game relay in/out** — game payloads on the normal WebSocket relay (channels other than signaling).
- **signaling relay in/out** — channel **65534** JSON (SDP/ICE) during WebRTC setup; usually small and stable after ICE completes.

## Demo

The demo scene **`demo/main.tscn`** logs **`[transport]`** and **`[p2p]`** lines to the in-game log when **`_debug`** is true. Enable **`RakiyClient.debug`** for **`[Rakiy]`** / **`[p2p]`** lines in the Godot output.

### Lobby list (`0x13`) and pose snapshot request

- **Lobby list** responses match the server’s **`encodeLobbyList`** layout: `u16` id length, `u8` member count, `u8` max players (`0xFF` = unset), `u16` name length, UTF-8 lobby id, UTF-8 display name.
- **`RakiyPack.FORMAT_APP_POSE_SNAPSHOT_REQUEST` (`0x0B`)**: optional **reliable** single-byte game payload. Recipients should reply with a full **v2** pose via **`RakiyPack.pack_player_state_from_dict`** sent **to the requesting peer** on **`CHANNEL_RELIABLE_GAME`**. The demo (and the **template-rakiy** project) broadcasts this once after **create/join lobby** when other members exist, so remote avatars get a keyframe immediately instead of waiting for the next periodic snapshot.

## Manual tests (cross-play)

1. **Web + desktop:** HTML5 with **`relay`** and desktop with **`p2p`**; same lobby; web traffic stays on the relay.
2. **Native + native:** Both **`p2p`**, WebRTC extension installed; verify signaling then **`game P2P`** counts and **`webrtc_dc_open`**.
3. **ICE failure:** Block UDP or bad STUN; data channels may not open; unreliable game is not duplicated on relay when **`p2p`** (see Send path).

Upstream may also track **[rakiy-godot-addon](https://github.com/cauldrongroup/rakiy-godot-addon)**; this monorepo copy aligns with **`multiplayer/protocol.md`**.
