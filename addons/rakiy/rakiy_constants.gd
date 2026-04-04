class_name RakiyConstants
extends RefCounted

## Handshake JSON field `v` (must match server; see Rakiy `multiplayer/protocol.md`).
const PROTOCOL_VERSION := 3

## Reliable / control-style traffic (project convention).
const CHANNEL_CONTROL := 0
const CHANNEL_RELIABLE_GAME := 1
const CHANNEL_UNRELIABLE_GAME := 2
## Reserved for WebRTC signaling JSON over the Rakiy relay (native `p2p` clients only).
const CHANNEL_SIGNALING := 65534

const TARGET_LOBBY_BROADCAST := 0

## Lobby member capability (matches wire byte).
const MEMBER_CAP_RELAY := 0
const MEMBER_CAP_P2P := 1

const CONTROL_MAGIC := 0x024B4152
const RELAY_MAGIC_V1 := 0x014B4152
const RELAY_MAGIC_V2 := 0x034B4152
