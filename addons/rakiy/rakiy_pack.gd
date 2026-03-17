class_name RakiyPack
extends RefCounted

## Compact binary encoding for player state (position, yaw, pitch).
## Use for high-frequency updates (e.g. 20 Hz) to reduce bandwidth ~60% vs JSON.
## Pass PackedByteArray result to send_data(); RakiyClient base64-encodes it automatically.
## unpack_player_state handles both binary and legacy JSON for backward compatibility.

const FORMAT_VERSION := 0x01
const BINARY_SIZE := 21

static func pack_player_state(position: Vector3, yaw: float, pitch: float) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(BINARY_SIZE)
	bytes[0] = FORMAT_VERSION
	bytes.encode_float(1, position.x)
	bytes.encode_float(5, position.y)
	bytes.encode_float(9, position.z)
	bytes.encode_float(13, pitch)
	bytes.encode_float(17, yaw)
	return bytes


static func unpack_player_state(payload: Variant) -> Variant:
	var s := str(payload)
	if s.begins_with("{"):
		return _unpack_json(s)
	return _unpack_binary(s)


static func _unpack_json(s: String) -> Variant:
	var parsed = JSON.parse_string(s)
	if parsed == null or not (parsed is Dictionary):
		return {}
	var d: Dictionary = parsed
	var p = d.get("p", [])
	if not (p is Array) or p.size() != 3:
		return {}
	return {
		"p": [float(p[0]), float(p[1]), float(p[2])],
		"y": float(d.get("y", 0.0)),
		"pitch": float(d.get("pitch", 0.0)),
	}


static func _unpack_binary(s: String) -> Variant:
	var bytes: PackedByteArray = Marshalls.base64_to_raw(s)
	if bytes.size() < BINARY_SIZE or bytes[0] != FORMAT_VERSION:
		return {}
	return {
		"p": [
			bytes.decode_float(1),
			bytes.decode_float(5),
			bytes.decode_float(9),
		],
		"y": bytes.decode_float(17),
		"pitch": bytes.decode_float(13),
	}
