class_name RakiyConstants
extends RefCounted

## Channel IDs for data frames. Use small integers; semantics match the Rakiy backend.
## See protocol: https://github.com/cauldrongroup/rakiy-godot-addon/blob/main/protocol.md

const CHANNEL_CONTROL := 0
const CHANNEL_RELIABLE_GAME := 1
const CHANNEL_UNRELIABLE_GAME := 2
