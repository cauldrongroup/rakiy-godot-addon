# Rakiy Godot add-on

Godot **4.x** client for the Rakiy multiplayer service: WebSocket relay, lobbies, optional **native P2P** (WebRTC) with signaling on relay channel **65534**.

## Files

| File | Role |
|------|------|
| `rakiy_client.gd` | WebSocket, handshake (`c`: `relay` / `p2p`), binary relay + lobby parsing |
| `rakiy_constants.gd` | Channel IDs, magic numbers, `CHANNEL_SIGNALING` |
| `rakiy_p2p.gd` | Optional WebRTC mesh: STUN/TURN, ICE, data channels; lower `peer_id` is the SDP offerer |

## Quick usage

```gdscript
# Web / HTML5 — relay only
RakiyClient.handshake_capability = "relay"
RakiyClient.connect_to_url("wss://your-host/", "Player")

# Native — optional P2P
RakiyClient.handshake_capability = "p2p"
var p2p := RakiyP2P.new()
RakiyClient.set_p2p_helper(p2p)
# Optional TURN (see docs / P2P page)
p2p.turn_servers = PackedStringArray(["turn:turn.example.com:3478"])
p2p.turn_username = "user"
p2p.turn_password = "pass"
RakiyClient.connect_to_url("wss://your-host/", "Player")
```

After `handshake_ok`, use `lobby_*` and `send_data` as usual. Game payloads use the relay unless a P2P data channel is open for that peer (`RakiyP2P.try_send_p2p` path inside `send_data`).

## Manual tests (cross-play)

1. **Web + desktop:** Run HTML5 export with `handshake_capability = "relay"` and desktop with `p2p`; same lobby; verify gameplay only uses relay for web legs (all traffic via server for paths involving web).
2. **Native + native:** Two desktop clients, both `p2p`; verify ICE connects (check `p2p_peer_connected`) and optionally wireshark / server metrics for reduced relay bytes for game channels.
3. **ICE failure:** Block UDP or misconfigure STUN; clients should fall back to relay for game data if you handle re-send on relay (current add-on sends relay when P2P is not `STATE_OPEN`).

Upstream releases may also track **[rakiy-godot-addon](https://github.com/cauldrongroup/rakiy-godot-addon)**; this monorepo copy stays aligned with the protocol in `multiplayer/protocol.md`.
