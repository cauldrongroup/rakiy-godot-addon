class_name RakiyReplication
extends RefCounted

## Helpers for interest-based replication and adaptive sync cadence (see Rakiy docs).


static func distance_squared(a: Vector3, b: Vector3) -> float:
	return a.distance_squared_to(b)


static func is_in_range(a: Vector3, b: Vector3, radius: float) -> bool:
	var r2: float = radius * radius
	return distance_squared(a, b) <= r2


## Returns peer ids from `peer_ids` that are within `radius` of `local_pos`.
## `peer_positions`: peer_id (int) -> Vector3 (last known position). Peers with no entry are included so you do not drop updates before the first packet.
static func filter_peers_by_interest(
	local_pos: Vector3,
	peer_positions: Dictionary,
	peer_ids: Array,
	radius: float,
) -> Array:
	var out: Array = []
	var r2: float = radius * radius
	for pid_v in peer_ids:
		var pid: int = int(pid_v)
		if not peer_positions.has(pid):
			out.append(pid)
			continue
		var p: Variant = peer_positions[pid]
		if p is Vector3 and distance_squared(local_pos, p as Vector3) <= r2:
			out.append(pid)
	return out


## Returns sync period in seconds: longer when stationary, shorter when moving.
## `base_hz`: nominal updates per second; `min_hz` / `max_hz`: clamp range for effective rate.
static func suggested_sync_interval(
	base_hz: float,
	min_hz: float,
	max_hz: float,
	velocity_sq: float,
	stationary_threshold_sq: float,
) -> float:
	var b: float = clampf(base_hz, 0.001, 120.0)
	var lo: float = clampf(min_hz, 0.001, b)
	var hi: float = clampf(max_hz, b, 240.0)
	var t: float = 0.0
	if velocity_sq <= stationary_threshold_sq:
		t = 1.0
	else:
		var vmax: float = maxf(stationary_threshold_sq, 1.0)
		t = clampf(velocity_sq / vmax, 0.0, 1.0)
	var eff_hz: float = lerpf(lo, hi, t)
	return 1.0 / eff_hz
