class_name RakiyPack
extends RefCounted

## Compact binary encoding for player state (position, yaw, pitch) and optional physics (velocity, angular).
## v2 uses half-floats (~11 bytes). v1 full floats (21 bytes) kept for decode only.
## Batch: legacy 0x03, compact pose 0x04, physics 0x05, physics+angular 0x08.
## Merged segments 0xFE: multiple payloads in one relay frame (one header on the wire).
## Selective 0x09: pose bitmask + only changed half-floats (bandwidth deltas).
## Selective physics 0x0A: u16 mask for pose + linear v + angular w half-floats.

const FORMAT_V1 := 0x01
const FORMAT_V2 := 0x02
const FORMAT_BATCH := 0x03
const FORMAT_BATCH_COMPACT := 0x04
const FORMAT_BATCH_PHYSICS := 0x05
const FORMAT_V3_PHYSICS := 0x06
const FORMAT_V4_PHYSICS_ANGULAR := 0x07
const FORMAT_BATCH_PHYSICS_ANGULAR := 0x08
const FORMAT_SELECTIVE_POSE := 0x09
const FORMAT_SELECTIVE_PHYSICS := 0x0A
## Reliable 1-byte app control: ask other lobby members to send a full pose keyframe to the requester (see demo / template session code).
const FORMAT_APP_POSE_SNAPSHOT_REQUEST := 0x0B
const FORMAT_MERGED_SEGMENTS := 0xFE

## Bit order matches encode order: px, py, pz, pitch, yaw, then vx..vz, wx..wz (0x0A only).
const MASK_POSE_PX := 1 << 0
const MASK_POSE_PY := 1 << 1
const MASK_POSE_PZ := 1 << 2
const MASK_POSE_PITCH := 1 << 3
const MASK_POSE_YAW := 1 << 4
const MASK_PHYS_VX := 1 << 5
const MASK_PHYS_VY := 1 << 6
const MASK_PHYS_VZ := 1 << 7
const MASK_PHYS_WX := 1 << 8
const MASK_PHYS_WY := 1 << 9
const MASK_PHYS_WZ := 1 << 10
const MASK_PHYS_POSE := 0x1F
const MASK_PHYS_LIN := 0xE0
const MASK_PHYS_ANG := 0x700
const MASK_PHYS_ALL := 0x7FF

const SIZE_V1 := 21
const SIZE_V2 := 11
const SIZE_V3_PHYSICS := 17
const SIZE_V4_PHYSICS_ANGULAR := 23
const HEADER_BATCH := 2
const RECORD_COMPACT_POSE := 10
const RECORD_PHYSICS := 16
const RECORD_PHYSICS_ANGULAR := 22

const HEADER_SELECTIVE_POSE := 2
const HEADER_SELECTIVE_PHYSICS := 3


static func _dict_pose_components(d: Dictionary) -> Dictionary:
	var p: Variant = d.get("p", Vector3.ZERO)
	var pos: Vector3
	if p is Vector3:
		pos = p
	elif p is Array:
		var a: Array = p
		var ax := float(a[0]) if a.size() > 0 else 0.0
		var ay := float(a[1]) if a.size() > 1 else 0.0
		var az := float(a[2]) if a.size() > 2 else 0.0
		pos = Vector3(ax, ay, az)
	else:
		pos = Vector3.ZERO
	var yaw: float = float(d.get("y", d.get("yaw", 0.0)))
	var pitch: float = float(d.get("pitch", 0.0))
	return {"pos": pos, "yaw": yaw, "pitch": pitch}


static func _dict_physics_vel(d: Dictionary) -> Vector3:
	var vv: Variant = d.get("v", Vector3.ZERO)
	return vv as Vector3 if vv is Vector3 else Vector3.ZERO


static func _dict_physics_ang(d: Dictionary) -> Vector3:
	var ww: Variant = d.get("w", Vector3.ZERO)
	return ww as Vector3 if ww is Vector3 else Vector3.ZERO


static func _popcount_mask_u16(mask: int, max_bit_inclusive: int) -> int:
	var c := 0
	for i in range(max_bit_inclusive + 1):
		if (mask >> i) & 1:
			c += 1
	return c


static func selective_pose_payload_size(mask: int) -> int:
	var m: int = mask & MASK_PHYS_POSE
	return HEADER_SELECTIVE_POSE + 2 * _popcount_mask_u16(m, 4)


static func should_use_selective_pose_payload(mask: int) -> bool:
	var m: int = mask & MASK_PHYS_POSE
	if m == 0:
		return false
	return selective_pose_payload_size(m) < SIZE_V2


static func selective_physics_payload_size(mask: int) -> int:
	var m: int = mask & MASK_PHYS_ALL
	return HEADER_SELECTIVE_PHYSICS + 2 * _popcount_mask_u16(m, 10)


static func should_use_selective_physics_payload(mask: int) -> bool:
	var m: int = mask & MASK_PHYS_ALL
	if m == 0:
		return false
	return selective_physics_payload_size(m) < SIZE_V4_PHYSICS_ANGULAR


static func compute_pose_delta_mask(previous: Dictionary, current: Dictionary, epsilon: float) -> int:
	var a: Dictionary = _dict_pose_components(previous)
	var b: Dictionary = _dict_pose_components(current)
	var ap: Vector3 = a.pos
	var bp: Vector3 = b.pos
	var mask := 0
	if absf(ap.x - bp.x) >= epsilon:
		mask |= MASK_POSE_PX
	if absf(ap.y - bp.y) >= epsilon:
		mask |= MASK_POSE_PY
	if absf(ap.z - bp.z) >= epsilon:
		mask |= MASK_POSE_PZ
	if absf(float(a.pitch) - float(b.pitch)) >= epsilon:
		mask |= MASK_POSE_PITCH
	if absf(float(a.yaw) - float(b.yaw)) >= epsilon:
		mask |= MASK_POSE_YAW
	return mask


static func compute_physics_delta_mask(previous: Dictionary, current: Dictionary, epsilon: float) -> int:
	var mask: int = compute_pose_delta_mask(previous, current, epsilon)
	var av: Vector3 = _dict_physics_vel(previous)
	var bv: Vector3 = _dict_physics_vel(current)
	if absf(av.x - bv.x) >= epsilon:
		mask |= MASK_PHYS_VX
	if absf(av.y - bv.y) >= epsilon:
		mask |= MASK_PHYS_VY
	if absf(av.z - bv.z) >= epsilon:
		mask |= MASK_PHYS_VZ
	var aw: Vector3 = _dict_physics_ang(previous)
	var bw: Vector3 = _dict_physics_ang(current)
	if absf(aw.x - bw.x) >= epsilon:
		mask |= MASK_PHYS_WX
	if absf(aw.y - bw.y) >= epsilon:
		mask |= MASK_PHYS_WY
	if absf(aw.z - bw.z) >= epsilon:
		mask |= MASK_PHYS_WZ
	return mask


static func pack_selective_pose(state: Dictionary, mask: int) -> PackedByteArray:
	var m: int = mask & MASK_PHYS_POSE
	if m == 0:
		return PackedByteArray()
	var c: Dictionary = _dict_pose_components(state)
	var pos: Vector3 = c.pos
	var out := PackedByteArray()
	out.resize(selective_pose_payload_size(m))
	out[0] = FORMAT_SELECTIVE_POSE
	out[1] = m & 0xFF
	var o := HEADER_SELECTIVE_POSE
	if m & MASK_POSE_PX:
		out.encode_half(o, pos.x)
		o += 2
	if m & MASK_POSE_PY:
		out.encode_half(o, pos.y)
		o += 2
	if m & MASK_POSE_PZ:
		out.encode_half(o, pos.z)
		o += 2
	if m & MASK_POSE_PITCH:
		out.encode_half(o, float(c.pitch))
		o += 2
	if m & MASK_POSE_YAW:
		out.encode_half(o, float(c.yaw))
		o += 2
	return out


static func pack_player_state_from_dict(state: Dictionary) -> PackedByteArray:
	var c: Dictionary = _dict_pose_components(state)
	return pack_player_state(c.pos, float(c.yaw), float(c.pitch))


static func pack_selective_pose_delta(
	previous: Dictionary,
	current: Dictionary,
	epsilon: float = 0.0001,
) -> PackedByteArray:
	var mask: int = compute_pose_delta_mask(previous, current, epsilon)
	if mask == 0:
		return PackedByteArray()
	if not should_use_selective_pose_payload(mask):
		return pack_player_state_from_dict(current)
	return pack_selective_pose(current, mask)


static func pack_selective_physics(state: Dictionary, mask: int) -> PackedByteArray:
	var m: int = mask & MASK_PHYS_ALL
	if m == 0:
		return PackedByteArray()
	var c: Dictionary = _dict_pose_components(state)
	var pos: Vector3 = c.pos
	var vel: Vector3 = _dict_physics_vel(state)
	var ang: Vector3 = _dict_physics_ang(state)
	var out := PackedByteArray()
	out.resize(selective_physics_payload_size(m))
	out[0] = FORMAT_SELECTIVE_PHYSICS
	out.encode_u16(1, m & 0xFFFF)
	var o := HEADER_SELECTIVE_PHYSICS
	if m & MASK_POSE_PX:
		out.encode_half(o, pos.x)
		o += 2
	if m & MASK_POSE_PY:
		out.encode_half(o, pos.y)
		o += 2
	if m & MASK_POSE_PZ:
		out.encode_half(o, pos.z)
		o += 2
	if m & MASK_POSE_PITCH:
		out.encode_half(o, float(c.pitch))
		o += 2
	if m & MASK_POSE_YAW:
		out.encode_half(o, float(c.yaw))
		o += 2
	if m & MASK_PHYS_VX:
		out.encode_half(o, vel.x)
		o += 2
	if m & MASK_PHYS_VY:
		out.encode_half(o, vel.y)
		o += 2
	if m & MASK_PHYS_VZ:
		out.encode_half(o, vel.z)
		o += 2
	if m & MASK_PHYS_WX:
		out.encode_half(o, ang.x)
		o += 2
	if m & MASK_PHYS_WY:
		out.encode_half(o, ang.y)
		o += 2
	if m & MASK_PHYS_WZ:
		out.encode_half(o, ang.z)
		o += 2
	return out


static func pack_player_physics_angular_from_dict(state: Dictionary) -> PackedByteArray:
	var c: Dictionary = _dict_pose_components(state)
	return pack_player_physics_state_angular(
		c.pos,
		float(c.yaw),
		float(c.pitch),
		_dict_physics_vel(state),
		_dict_physics_ang(state),
	)


static func pack_selective_physics_delta(
	previous: Dictionary,
	current: Dictionary,
	epsilon: float = 0.0001,
) -> PackedByteArray:
	var mask: int = compute_physics_delta_mask(previous, current, epsilon)
	if mask == 0:
		return PackedByteArray()
	if not should_use_selective_physics_payload(mask):
		return pack_player_physics_angular_from_dict(current)
	return pack_selective_physics(current, mask)


static func apply_selective_pose(base: Dictionary, payload: PackedByteArray) -> Dictionary:
	var out: Dictionary = base.duplicate(true)
	if payload.size() < HEADER_SELECTIVE_POSE or payload[0] != FORMAT_SELECTIVE_POSE:
		return out
	var m: int = int(payload[1]) & MASK_PHYS_POSE
	var expected: int = selective_pose_payload_size(m)
	if payload.size() != expected:
		return out
	var c: Dictionary = _dict_pose_components(out)
	var pos: Vector3 = c.pos
	var o := HEADER_SELECTIVE_POSE
	if m & MASK_POSE_PX:
		pos.x = payload.decode_half(o)
		o += 2
	if m & MASK_POSE_PY:
		pos.y = payload.decode_half(o)
		o += 2
	if m & MASK_POSE_PZ:
		pos.z = payload.decode_half(o)
		o += 2
	var pitch: float = float(c.pitch)
	var yaw: float = float(c.yaw)
	if m & MASK_POSE_PITCH:
		pitch = payload.decode_half(o)
		o += 2
	if m & MASK_POSE_YAW:
		yaw = payload.decode_half(o)
		o += 2
	out["p"] = pos
	out["pitch"] = pitch
	out["y"] = yaw
	return out


static func apply_selective_physics(base: Dictionary, payload: PackedByteArray) -> Dictionary:
	if payload.size() >= HEADER_SELECTIVE_PHYSICS and payload[0] == FORMAT_SELECTIVE_PHYSICS:
		var m: int = int(payload.decode_u16(1)) & MASK_PHYS_ALL
		var expected: int = selective_physics_payload_size(m)
		if payload.size() != expected:
			return base.duplicate(true)
		var out: Dictionary = base.duplicate(true)
		var c: Dictionary = _dict_pose_components(out)
		var pos: Vector3 = c.pos
		var vel: Vector3 = _dict_physics_vel(out)
		var ang: Vector3 = _dict_physics_ang(out)
		var o := HEADER_SELECTIVE_PHYSICS
		if m & MASK_POSE_PX:
			pos.x = payload.decode_half(o)
			o += 2
		if m & MASK_POSE_PY:
			pos.y = payload.decode_half(o)
			o += 2
		if m & MASK_POSE_PZ:
			pos.z = payload.decode_half(o)
			o += 2
		var pitch: float = float(c.pitch)
		var yaw: float = float(c.yaw)
		if m & MASK_POSE_PITCH:
			pitch = payload.decode_half(o)
			o += 2
		if m & MASK_POSE_YAW:
			yaw = payload.decode_half(o)
			o += 2
		out["p"] = pos
		out["pitch"] = pitch
		out["y"] = yaw
		if m & MASK_PHYS_VX:
			vel.x = payload.decode_half(o)
			o += 2
		if m & MASK_PHYS_VY:
			vel.y = payload.decode_half(o)
			o += 2
		if m & MASK_PHYS_VZ:
			vel.z = payload.decode_half(o)
			o += 2
		if m & MASK_PHYS_WX:
			ang.x = payload.decode_half(o)
			o += 2
		if m & MASK_PHYS_WY:
			ang.y = payload.decode_half(o)
			o += 2
		if m & MASK_PHYS_WZ:
			ang.z = payload.decode_half(o)
			o += 2
		out["v"] = vel
		out["w"] = ang
		return out
	return apply_selective_pose(base, payload)


static func unpack_selective_pose(payload: Variant) -> Dictionary:
	if not (payload is PackedByteArray):
		return {}
	var p: PackedByteArray = payload
	if p.size() < HEADER_SELECTIVE_POSE or p[0] != FORMAT_SELECTIVE_POSE:
		return {}
	var m: int = int(p[1]) & MASK_PHYS_POSE
	if p.size() != selective_pose_payload_size(m):
		return {}
	var o := HEADER_SELECTIVE_POSE
	var out := {"mask": m}
	if m & MASK_POSE_PX:
		out["px"] = p.decode_half(o)
		o += 2
	if m & MASK_POSE_PY:
		out["py"] = p.decode_half(o)
		o += 2
	if m & MASK_POSE_PZ:
		out["pz"] = p.decode_half(o)
		o += 2
	if m & MASK_POSE_PITCH:
		out["pitch"] = p.decode_half(o)
		o += 2
	if m & MASK_POSE_YAW:
		out["y"] = p.decode_half(o)
		o += 2
	return out


static func unpack_selective_physics(payload: Variant) -> Dictionary:
	if not (payload is PackedByteArray):
		return {}
	var p: PackedByteArray = payload
	if p.size() < HEADER_SELECTIVE_PHYSICS or p[0] != FORMAT_SELECTIVE_PHYSICS:
		return {}
	var m: int = int(p.decode_u16(1)) & MASK_PHYS_ALL
	if p.size() != selective_physics_payload_size(m):
		return {}
	var o := HEADER_SELECTIVE_PHYSICS
	var out := {"mask": m}
	if m & MASK_POSE_PX:
		out["px"] = p.decode_half(o)
		o += 2
	if m & MASK_POSE_PY:
		out["py"] = p.decode_half(o)
		o += 2
	if m & MASK_POSE_PZ:
		out["pz"] = p.decode_half(o)
		o += 2
	if m & MASK_POSE_PITCH:
		out["pitch"] = p.decode_half(o)
		o += 2
	if m & MASK_POSE_YAW:
		out["y"] = p.decode_half(o)
		o += 2
	if m & MASK_PHYS_VX:
		out["vx"] = p.decode_half(o)
		o += 2
	if m & MASK_PHYS_VY:
		out["vy"] = p.decode_half(o)
		o += 2
	if m & MASK_PHYS_VZ:
		out["vz"] = p.decode_half(o)
		o += 2
	if m & MASK_PHYS_WX:
		out["wx"] = p.decode_half(o)
		o += 2
	if m & MASK_PHYS_WY:
		out["wy"] = p.decode_half(o)
		o += 2
	if m & MASK_PHYS_WZ:
		out["wz"] = p.decode_half(o)
		o += 2
	return out


static func pack_player_state(position: Vector3, yaw: float, pitch: float) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(SIZE_V2)
	bytes[0] = FORMAT_V2
	bytes.encode_half(1, position.x)
	bytes.encode_half(3, position.y)
	bytes.encode_half(5, position.z)
	bytes.encode_half(7, pitch)
	bytes.encode_half(9, yaw)
	return bytes


static func pack_player_physics_state(
	position: Vector3,
	yaw: float,
	pitch: float,
	linear_velocity: Vector3,
) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(SIZE_V3_PHYSICS)
	bytes[0] = FORMAT_V3_PHYSICS
	bytes.encode_half(1, position.x)
	bytes.encode_half(3, position.y)
	bytes.encode_half(5, position.z)
	bytes.encode_half(7, pitch)
	bytes.encode_half(9, yaw)
	bytes.encode_half(11, linear_velocity.x)
	bytes.encode_half(13, linear_velocity.y)
	bytes.encode_half(15, linear_velocity.z)
	return bytes


static func pack_player_physics_state_angular(
	position: Vector3,
	yaw: float,
	pitch: float,
	linear_velocity: Vector3,
	angular_velocity: Vector3,
) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(SIZE_V4_PHYSICS_ANGULAR)
	bytes[0] = FORMAT_V4_PHYSICS_ANGULAR
	bytes.encode_half(1, position.x)
	bytes.encode_half(3, position.y)
	bytes.encode_half(5, position.z)
	bytes.encode_half(7, pitch)
	bytes.encode_half(9, yaw)
	bytes.encode_half(11, linear_velocity.x)
	bytes.encode_half(13, linear_velocity.y)
	bytes.encode_half(15, linear_velocity.z)
	bytes.encode_half(17, angular_velocity.x)
	bytes.encode_half(19, angular_velocity.y)
	bytes.encode_half(21, angular_velocity.z)
	return bytes


static func pack_player_states_batch(states: Array) -> PackedByteArray:
	## Each element: Dictionary with keys p (Vector3), y (yaw float), pitch (float). Emits compact batch 0x04.
	var n: int = mini(states.size(), 255)
	if n <= 0:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(HEADER_BATCH + n * RECORD_COMPACT_POSE)
	out[0] = FORMAT_BATCH_COMPACT
	out[1] = n
	var o := HEADER_BATCH
	for i in range(n):
		var s: Variant = states[i]
		if s is Dictionary:
			var d: Dictionary = s
			var p: Variant = d.get("p", Vector3.ZERO)
			var pos: Vector3 = p as Vector3 if p is Vector3 else Vector3.ZERO
			var pitch: float = float(d.get("pitch", 0.0))
			var yaw: float = float(d.get("y", d.get("yaw", 0.0)))
			out.encode_half(o, pos.x)
			out.encode_half(o + 2, pos.y)
			out.encode_half(o + 4, pos.z)
			out.encode_half(o + 6, pitch)
			out.encode_half(o + 8, yaw)
		o += RECORD_COMPACT_POSE
	return out


static func pack_player_states_physics_batch(states: Array) -> PackedByteArray:
	## Each element: Dictionary with p, y/yaw, pitch, v (Vector3 linear velocity).
	var n: int = mini(states.size(), 255)
	if n <= 0:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(HEADER_BATCH + n * RECORD_PHYSICS)
	out[0] = FORMAT_BATCH_PHYSICS
	out[1] = n
	var o := HEADER_BATCH
	for i in range(n):
		var s: Variant = states[i]
		var pos := Vector3.ZERO
		var pitch := 0.0
		var yaw := 0.0
		var vel := Vector3.ZERO
		if s is Dictionary:
			var d: Dictionary = s
			var p: Variant = d.get("p", Vector3.ZERO)
			pos = p as Vector3 if p is Vector3 else Vector3.ZERO
			pitch = float(d.get("pitch", 0.0))
			yaw = float(d.get("y", d.get("yaw", 0.0)))
			var vv: Variant = d.get("v", Vector3.ZERO)
			vel = vv as Vector3 if vv is Vector3 else Vector3.ZERO
		out.encode_half(o, pos.x)
		out.encode_half(o + 2, pos.y)
		out.encode_half(o + 4, pos.z)
		out.encode_half(o + 6, pitch)
		out.encode_half(o + 8, yaw)
		out.encode_half(o + 10, vel.x)
		out.encode_half(o + 12, vel.y)
		out.encode_half(o + 14, vel.z)
		o += RECORD_PHYSICS
	return out


static func pack_player_states_physics_angular_batch(states: Array) -> PackedByteArray:
	## Each element: Dictionary with p, y/yaw, pitch, v, w (angular Vector3).
	var n: int = mini(states.size(), 255)
	if n <= 0:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(HEADER_BATCH + n * RECORD_PHYSICS_ANGULAR)
	out[0] = FORMAT_BATCH_PHYSICS_ANGULAR
	out[1] = n
	var o := HEADER_BATCH
	for i in range(n):
		var s: Variant = states[i]
		var pos := Vector3.ZERO
		var pitch := 0.0
		var yaw := 0.0
		var vel := Vector3.ZERO
		var ang := Vector3.ZERO
		if s is Dictionary:
			var d: Dictionary = s
			var p: Variant = d.get("p", Vector3.ZERO)
			pos = p as Vector3 if p is Vector3 else Vector3.ZERO
			pitch = float(d.get("pitch", 0.0))
			yaw = float(d.get("y", d.get("yaw", 0.0)))
			var vv: Variant = d.get("v", Vector3.ZERO)
			vel = vv as Vector3 if vv is Vector3 else Vector3.ZERO
			var ww: Variant = d.get("w", Vector3.ZERO)
			ang = ww as Vector3 if ww is Vector3 else Vector3.ZERO
		out.encode_half(o, pos.x)
		out.encode_half(o + 2, pos.y)
		out.encode_half(o + 4, pos.z)
		out.encode_half(o + 6, pitch)
		out.encode_half(o + 8, yaw)
		out.encode_half(o + 10, vel.x)
		out.encode_half(o + 12, vel.y)
		out.encode_half(o + 14, vel.z)
		out.encode_half(o + 16, ang.x)
		out.encode_half(o + 18, ang.y)
		out.encode_half(o + 20, ang.z)
		o += RECORD_PHYSICS_ANGULAR
	return out


static func pack_player_states_batch_legacy(states: Array) -> PackedByteArray:
	## Legacy 0x03 batch with per-record FORMAT_V2 byte (11 bytes per record).
	var n: int = mini(states.size(), 255)
	if n <= 0:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(HEADER_BATCH + n * SIZE_V2)
	out[0] = FORMAT_BATCH
	out[1] = n
	var o := HEADER_BATCH
	for i in range(n):
		var s: Variant = states[i]
		if s is Dictionary:
			var d: Dictionary = s
			var p: Variant = d.get("p", Vector3.ZERO)
			var pos: Vector3 = p as Vector3 if p is Vector3 else Vector3.ZERO
			var pitch: float = float(d.get("pitch", 0.0))
			var yaw: float = float(d.get("y", d.get("yaw", 0.0)))
			out[o] = FORMAT_V2
			out.encode_half(o + 1, pos.x)
			out.encode_half(o + 3, pos.y)
			out.encode_half(o + 5, pos.z)
			out.encode_half(o + 7, pitch)
			out.encode_half(o + 9, yaw)
		o += SIZE_V2
	return out


static func pack_merged_segments(segments: Array) -> PackedByteArray:
	## Each element: PackedByteArray. Max 255 segments; each length max 65535.
	var valid: Array = []
	for s in segments:
		if s is PackedByteArray and valid.size() < 255:
			valid.append(s)
	if valid.is_empty():
		return PackedByteArray()
	var out := PackedByteArray()
	out.append(FORMAT_MERGED_SEGMENTS)
	out.append(valid.size())
	for seg in valid:
		var b: PackedByteArray = seg
		var slen: int = mini(b.size(), 65535)
		out.append(slen & 0xFF)
		out.append((slen >> 8) & 0xFF)
		out.append_array(b.slice(0, slen))
	return out


static func unpack_merged_segments(payload: Variant) -> Array:
	var out: Array = []
	if not (payload is PackedByteArray):
		return out
	var p: PackedByteArray = payload
	if p.size() < 2 or p[0] != FORMAT_MERGED_SEGMENTS:
		return out
	var n: int = int(p[1])
	var o := 2
	for _i in range(n):
		if o + 2 > p.size():
			break
		var slen: int = int(p.decode_u16(o))
		o += 2
		if o + slen > p.size():
			break
		out.append(p.slice(o, o + slen))
		o += slen
	return out


static func unpack_player_state(payload: Variant) -> Variant:
	if payload is PackedByteArray:
		return _unpack_bytes(payload as PackedByteArray)
	return {}


static func _unpack_bytes(b: PackedByteArray) -> Variant:
	if b.is_empty():
		return {}
	var ver: int = int(b[0])
	if ver == FORMAT_V2 and b.size() >= SIZE_V2:
		return {
			"p": [
				b.decode_half(1),
				b.decode_half(3),
				b.decode_half(5),
			],
			"y": b.decode_half(9),
			"pitch": b.decode_half(7),
		}
	if ver == FORMAT_V3_PHYSICS and b.size() >= SIZE_V3_PHYSICS:
		return {
			"p": [
				b.decode_half(1),
				b.decode_half(3),
				b.decode_half(5),
			],
			"y": b.decode_half(9),
			"pitch": b.decode_half(7),
			"v": Vector3(b.decode_half(11), b.decode_half(13), b.decode_half(15)),
		}
	if ver == FORMAT_V4_PHYSICS_ANGULAR and b.size() >= SIZE_V4_PHYSICS_ANGULAR:
		return {
			"p": [
				b.decode_half(1),
				b.decode_half(3),
				b.decode_half(5),
			],
			"y": b.decode_half(9),
			"pitch": b.decode_half(7),
			"v": Vector3(b.decode_half(11), b.decode_half(13), b.decode_half(15)),
			"w": Vector3(b.decode_half(17), b.decode_half(19), b.decode_half(21)),
		}
	if ver == FORMAT_V1 and b.size() >= SIZE_V1:
		return {
			"p": [
				b.decode_float(1),
				b.decode_float(5),
				b.decode_float(9),
			],
			"y": b.decode_float(17),
			"pitch": b.decode_float(13),
		}
	if ver == FORMAT_SELECTIVE_POSE and b.size() >= HEADER_SELECTIVE_POSE:
		var mp: int = int(b[1]) & MASK_PHYS_POSE
		if b.size() == selective_pose_payload_size(mp):
			return unpack_selective_pose(b)
	if ver == FORMAT_SELECTIVE_PHYSICS and b.size() >= HEADER_SELECTIVE_PHYSICS:
		var mphy: int = int(b.decode_u16(1)) & MASK_PHYS_ALL
		if b.size() == selective_physics_payload_size(mphy):
			return unpack_selective_physics(b)
	return {}


static func _unpack_pose_compact_slice(slice: PackedByteArray) -> Dictionary:
	if slice.size() < RECORD_COMPACT_POSE:
		return {}
	return {
		"p": [
			slice.decode_half(0),
			slice.decode_half(2),
			slice.decode_half(4),
		],
		"y": slice.decode_half(8),
		"pitch": slice.decode_half(6),
	}


static func unpack_player_states_batch(payload: Variant) -> Array:
	var out: Array = []
	if not (payload is PackedByteArray):
		return out
	var b: PackedByteArray = payload
	if b.size() < HEADER_BATCH:
		return out
	var kind: int = int(b[0])
	var n: int = int(b[1])
	var o := HEADER_BATCH
	if kind == FORMAT_BATCH:
		for _i in range(n):
			if o + SIZE_V2 > b.size():
				break
			var slice := b.slice(o, o + SIZE_V2)
			var one: Variant = _unpack_bytes(slice)
			if one is Dictionary and not (one as Dictionary).is_empty():
				out.append(one)
			o += SIZE_V2
		return out
	if kind == FORMAT_BATCH_COMPACT:
		for _i in range(n):
			if o + RECORD_COMPACT_POSE > b.size():
				break
			var sl := b.slice(o, o + RECORD_COMPACT_POSE)
			var d := _unpack_pose_compact_slice(sl)
			if not d.is_empty():
				out.append(d)
			o += RECORD_COMPACT_POSE
		return out
	if kind == FORMAT_BATCH_PHYSICS:
		for _i in range(n):
			if o + RECORD_PHYSICS > b.size():
				break
			var sl2 := b.slice(o, o + RECORD_PHYSICS)
			var d2: Dictionary = _unpack_pose_compact_slice(sl2.slice(0, RECORD_COMPACT_POSE))
			if d2.is_empty():
				o += RECORD_PHYSICS
				continue
			d2["v"] = Vector3(sl2.decode_half(10), sl2.decode_half(12), sl2.decode_half(14))
			out.append(d2)
			o += RECORD_PHYSICS
		return out
	if kind == FORMAT_BATCH_PHYSICS_ANGULAR:
		for _i in range(n):
			if o + RECORD_PHYSICS_ANGULAR > b.size():
				break
			var sl3 := b.slice(o, o + RECORD_PHYSICS_ANGULAR)
			var d3: Dictionary = _unpack_pose_compact_slice(sl3.slice(0, RECORD_COMPACT_POSE))
			if d3.is_empty():
				o += RECORD_PHYSICS_ANGULAR
				continue
			d3["v"] = Vector3(sl3.decode_half(10), sl3.decode_half(12), sl3.decode_half(14))
			d3["w"] = Vector3(sl3.decode_half(16), sl3.decode_half(18), sl3.decode_half(20))
			out.append(d3)
			o += RECORD_PHYSICS_ANGULAR
		return out
	return out
