extends Node3D

## Rakiy demo: lobby UI + 3D arena with FPS movement and RakiyPack pose sync (unreliable channel).

const _RakiyDemoWorldScript := preload("res://addons/rakiy/demo/demo_world.gd")

const _RakiyClientScript := preload("res://addons/rakiy/rakiy_client.gd")
const _FpsScene := preload("res://addons/rakiy/demo/fps_player.tscn")
const _RemoteAvatarScene := preload("res://addons/rakiy/demo/remote_avatar.tscn")

const _DEMO_GAME_ID := "rakiy_demo"
const _SYNC_HZ := 20.0
const _MIN_SYNC_HZ := 8.0
const _MAX_SYNC_HZ := 24.0
const _STATIONARY_VEL_SQ := 0.08
const _INTEREST_RADIUS := 80.0
## Full pose snapshot (v2) every N sync ticks so peers can recover after unreliable packet loss (bandwidth tradeoff).
const _FULL_SNAPSHOT_EVERY_N_TICKS := 40

var _debug := true

@onready var _ui = $DemoUI
@onready var _players_root: Node3D = $World/Players

func _demo_log(msg: String) -> void:
	if _debug:
		print("[Rakiy Demo] ", msg)

var _last_sent_pose: Dictionary = {}
var _remote_pose_state: Dictionary = {}
var _sync_accum: float = 0.0
var _sync_tick_count: int = 0

var _local_player: CharacterBody3D
var _remote_avatars: Dictionary = {}

var _current_lobby_id: String = ""
var _current_members: Array = []


func _ready() -> void:
	var root := get_tree().root
	if root.get_node_or_null("RakiyClient") == null:
		_demo_log("RakiyClient autoload not found, adding client as child node")
		var client: Node = _RakiyClientScript.new()
		client.name = "RakiyClient"
		add_child(client)
	else:
		_demo_log("Using RakiyClient autoload from root")

	var _rc := _get_client()
	if _rc != null:
		# Flood guard: one outbound frame per sync tick (broadcast counts as 1); raise if needed.
		_rc.unreliable_send_rate_cap = 240
		_rc.unreliable_send_rate_window_sec = 1.0

	_RakiyDemoWorldScript.build($World)
	_connect_signals()
	_update_ui_state()


func _get_client() -> Node:
	var root := get_tree().root
	var c: Node = root.get_node_or_null("RakiyClient")
	if c != null:
		return c
	return get_node_or_null("RakiyClient")


func _connect_signals() -> void:
	_ui.connect_btn.pressed.connect(_on_connect_pressed)
	_ui.disconnect_btn.pressed.connect(_on_disconnect_pressed)
	_ui.create_btn.pressed.connect(_on_create_lobby_pressed)
	_ui.join_btn.pressed.connect(_on_join_pressed)
	_ui.leave_btn.pressed.connect(_on_leave_pressed)
	_ui.refresh_btn.pressed.connect(_on_refresh_pressed)
	_ui.send_btn.pressed.connect(_on_send_pressed)
	_ui.copy_lobby_id_btn.pressed.connect(_on_copy_lobby_id_pressed)
	var client := _get_client()
	if client == null:
		_ui.set_status_raw("Error: RakiyClient autoload missing.")
		return
	client.websocket_opened.connect(_on_websocket_opened)
	client.disconnected.connect(_on_disconnected)
	client.handshake_ok.connect(_on_handshake_ok)
	client.handshake_fail.connect(_on_handshake_fail)
	client.lobby_created.connect(_on_lobby_created)
	client.lobby_joined.connect(_on_lobby_joined)
	client.lobby_left.connect(_on_lobby_left)
	client.lobby_list_received.connect(_on_lobby_list_received)
	client.lobby_member_joined.connect(_on_lobby_member_joined)
	client.lobby_member_left.connect(_on_lobby_member_left)
	client.lobby_error.connect(_on_lobby_error)
	client.data_received.connect(_on_data_received)


func _exit_tree() -> void:
	var client := _get_client()
	if client == null:
		return
	if client.websocket_opened.is_connected(_on_websocket_opened):
		client.websocket_opened.disconnect(_on_websocket_opened)
	if client.disconnected.is_connected(_on_disconnected):
		client.disconnected.disconnect(_on_disconnected)
	if client.handshake_ok.is_connected(_on_handshake_ok):
		client.handshake_ok.disconnect(_on_handshake_ok)
	if client.handshake_fail.is_connected(_on_handshake_fail):
		client.handshake_fail.disconnect(_on_handshake_fail)
	if client.lobby_created.is_connected(_on_lobby_created):
		client.lobby_created.disconnect(_on_lobby_created)
	if client.lobby_joined.is_connected(_on_lobby_joined):
		client.lobby_joined.disconnect(_on_lobby_joined)
	if client.lobby_left.is_connected(_on_lobby_left):
		client.lobby_left.disconnect(_on_lobby_left)
	if client.lobby_list_received.is_connected(_on_lobby_list_received):
		client.lobby_list_received.disconnect(_on_lobby_list_received)
	if client.lobby_member_joined.is_connected(_on_lobby_member_joined):
		client.lobby_member_joined.disconnect(_on_lobby_member_joined)
	if client.lobby_member_left.is_connected(_on_lobby_member_left):
		client.lobby_member_left.disconnect(_on_lobby_member_left)
	if client.lobby_error.is_connected(_on_lobby_error):
		client.lobby_error.disconnect(_on_lobby_error)
	if client.data_received.is_connected(_on_data_received):
		client.data_received.disconnect(_on_data_received)


func _physics_process(delta: float) -> void:
	if _current_lobby_id.is_empty() or _local_player == null:
		return
	var vel_sq: float = _local_player.velocity.length_squared()
	var interval: float = RakiyReplication.suggested_sync_interval(
		_SYNC_HZ,
		_MIN_SYNC_HZ,
		_MAX_SYNC_HZ,
		vel_sq,
		_STATIONARY_VEL_SQ,
	)
	_sync_accum += delta
	if _sync_accum < interval:
		return
	_sync_accum = 0.0
	_broadcast_pose_if_playing()


func _broadcast_pose_if_playing() -> void:
	if _current_lobby_id.is_empty() or _local_player == null:
		return
	var client := _get_client()
	if client == null or not client.is_handshaken():
		return
	var st: Dictionary = _local_player.get_pose_dict()
	_sync_tick_count += 1
	var force_keyframe: bool = (_sync_tick_count % _FULL_SNAPSHOT_EVERY_N_TICKS) == 0
	var pkt: PackedByteArray
	if force_keyframe:
		pkt = RakiyPack.pack_player_state_from_dict(st)
	else:
		pkt = RakiyPack.pack_selective_pose_delta(_last_sent_pose, st)
		if pkt.is_empty():
			return
	var self_id: int = client.get_peer_id()
	var others: Array = _other_member_peer_ids(self_id)
	if others.is_empty():
		_last_sent_pose = st.duplicate(true)
		return
	var pos_map: Dictionary = _peer_positions_for_interest()
	var relevant: Array = RakiyReplication.filter_peers_by_interest(
		_local_player.global_position,
		pos_map,
		others,
		_INTEREST_RADIUS,
	)
	if relevant.is_empty():
		return
	if _peer_id_set_equals(relevant, others):
		client.send_lobby_broadcast(RakiyConstants.CHANNEL_UNRELIABLE_GAME, false, pkt)
	else:
		for pid_v in relevant:
			client.send_data(int(pid_v), RakiyConstants.CHANNEL_UNRELIABLE_GAME, false, pkt)
	_last_sent_pose = st.duplicate(true)


func _other_member_peer_ids(self_id: int) -> Array:
	var out: Array = []
	for m in _current_members:
		if not m is Dictionary:
			continue
		var pid: int = int(m.get("peer_id", -1))
		if pid >= 0 and pid != self_id:
			out.append(pid)
	return out


func _peer_positions_for_interest() -> Dictionary:
	var d := {}
	for m in _current_members:
		if not m is Dictionary:
			continue
		var pid: int = int(m.get("peer_id", -1))
		if pid < 0:
			continue
		var st: Variant = _remote_pose_state.get(pid, null)
		if st is Dictionary:
			var p: Variant = (st as Dictionary).get("p", null)
			if p is Vector3:
				d[pid] = p
	return d


func _peer_id_set_equals(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var aa: Array = a.duplicate()
	var bb: Array = b.duplicate()
	aa.sort()
	bb.sort()
	return aa == bb


func _dictionary_from_unpack(u: Variant) -> Dictionary:
	if u is not Dictionary:
		return {}
	var d: Dictionary = u
	var p: Variant = d.get("p", Vector3.ZERO)
	var pos: Vector3
	if p is Vector3:
		pos = p as Vector3
	elif p is Array:
		var a: Array = p
		if a.size() >= 3:
			pos = Vector3(float(a[0]), float(a[1]), float(a[2]))
		else:
			pos = Vector3.ZERO
	else:
		pos = Vector3.ZERO
	return {
		"p": pos,
		"y": float(d.get("y", d.get("yaw", 0.0))),
		"pitch": float(d.get("pitch", 0.0)),
	}


func _apply_incoming_pose(peer_id: int, pkt: PackedByteArray) -> void:
	if pkt.is_empty():
		return
	var kind: int = int(pkt[0])
	var merged: Dictionary
	if kind == RakiyPack.FORMAT_SELECTIVE_POSE:
		var prev: Dictionary = _remote_pose_state.get(peer_id, {})
		merged = RakiyPack.apply_selective_pose(prev, pkt)
	elif kind == RakiyPack.FORMAT_V2 or kind == RakiyPack.FORMAT_V3_PHYSICS or kind == RakiyPack.FORMAT_V4_PHYSICS_ANGULAR:
		var u: Variant = RakiyPack.unpack_player_state(pkt)
		merged = _dictionary_from_unpack(u)
	else:
		return
	if merged.is_empty():
		return
	_remote_pose_state[peer_id] = merged
	_ensure_remote_avatar(peer_id, "")
	var av: Node = _remote_avatars.get(peer_id, null)
	if av != null and av.has_method("apply_network_state"):
		av.call("apply_network_state", merged)


func _peer_color(peer_id: int) -> Color:
	var rng := RandomNumberGenerator.new()
	rng.seed = peer_id
	return Color(rng.randf_range(0.35, 1.0), rng.randf_range(0.35, 1.0), rng.randf_range(0.35, 1.0))


func _username_for_peer(peer_id: int) -> String:
	for m in _current_members:
		if m is Dictionary and int(m.get("peer_id", -1)) == peer_id:
			return str(m.get("username", ""))
	return ""


func _display_name_for_peer(peer_id: int, hint: String = "") -> String:
	var n := hint.strip_edges() if not hint.strip_edges().is_empty() else _username_for_peer(peer_id)
	if n.is_empty():
		return "Peer %d" % peer_id
	return n


func _ensure_remote_avatar(peer_id: int, username_hint: String = "") -> void:
	var client := _get_client()
	if client != null and peer_id == client.get_peer_id():
		return
	var display_name: String = _display_name_for_peer(peer_id, username_hint)
	if _remote_avatars.has(peer_id):
		var existing: Node = _remote_avatars[peer_id] as Node
		if existing != null and existing.has_method("set_username"):
			existing.call("set_username", display_name)
		return
	var av: Node3D = _RemoteAvatarScene.instantiate() as Node3D
	_players_root.add_child(av)
	av.name = "Peer_%d" % peer_id
	if av.has_method("set_peer_color"):
		av.call("set_peer_color", _peer_color(peer_id))
	if av.has_method("set_username"):
		av.call("set_username", display_name)
	_remote_avatars[peer_id] = av


func _destroy_remote_avatar(peer_id: int) -> void:
	if _remote_avatars.has(peer_id):
		var n: Node = _remote_avatars[peer_id] as Node
		if n != null and is_instance_valid(n):
			n.queue_free()
		_remote_avatars.erase(peer_id)
	_remote_pose_state.erase(peer_id)


func _sync_remote_roster() -> void:
	var client := _get_client()
	if client == null:
		return
	var self_id: int = client.get_peer_id()
	for m in _current_members:
		if not m is Dictionary:
			continue
		var pid: int = int(m.get("peer_id", -1))
		if pid < 0 or pid == self_id:
			continue
		var uname: String = str(m.get("username", ""))
		_ensure_remote_avatar(pid, uname)


func _ensure_local_player() -> void:
	if _local_player != null and is_instance_valid(_local_player):
		return
	_last_sent_pose.clear()
	_sync_tick_count = 0
	var p: CharacterBody3D = _FpsScene.instantiate() as CharacterBody3D
	p.global_position = Vector3(randf_range(-10.0, 10.0), 1.0, randf_range(-10.0, 10.0))
	_players_root.add_child(p)
	_local_player = p
	var uname: String = _ui.username_edit.text.strip_edges()
	if uname.is_empty():
		uname = "Player"
	if p.has_method("set_username"):
		p.call("set_username", uname)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _clear_multiplayer_3d() -> void:
	_last_sent_pose.clear()
	_sync_tick_count = 0
	_remote_pose_state.clear()
	var ids: Array = _remote_avatars.keys()
	for id in ids:
		_destroy_remote_avatar(int(id))
	_remote_avatars.clear()
	if _local_player != null and is_instance_valid(_local_player):
		_local_player.queue_free()
	_local_player = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _update_ui_state() -> void:
	var client: Node = _get_client()
	var conn: bool = client != null and client.is_connected_to_host()
	var handshaken: bool = client != null and client.is_handshaken()
	var connecting: bool = client != null and client.is_connecting()
	var pid: int = -1
	if client != null and handshaken:
		pid = client.get_peer_id()
	_ui.apply_connection_state(conn, handshaken, connecting, pid, not _current_lobby_id.is_empty())


func _on_connect_pressed() -> void:
	var client := _get_client()
	if client == null:
		_ui.set_status_raw("Error: RakiyClient not found.")
		return
	client.connect_to_url(_ui.url_edit.text.strip_edges(), _ui.username_edit.text.strip_edges())
	_update_ui_state()


func _on_disconnect_pressed() -> void:
	var client := _get_client()
	if client:
		client.disconnect_from_host()
	_current_lobby_id = ""
	_current_members.clear()
	_clear_multiplayer_3d()
	_refresh_members_list()
	_update_ui_state()
	_ui.current_lobby_label.text = "No lobby"


func _on_handshake_ok(_peer_id: int) -> void:
	_update_ui_state()
	_ui.go_to_lobby_tab()
	var client := _get_client()
	if client:
		client.lobby_list(_DEMO_GAME_ID, true)


func _on_handshake_fail(reason: String) -> void:
	_update_ui_state()
	_ui.set_status_raw("Handshake failed: %s" % reason)


func _process(_delta: float) -> void:
	var client: Node = _get_client()
	if client != null and client.is_connecting():
		_update_ui_state()


func _on_websocket_opened() -> void:
	_update_ui_state()


func _on_disconnected() -> void:
	_current_lobby_id = ""
	_current_members.clear()
	_clear_multiplayer_3d()
	_refresh_members_list()
	_update_ui_state()
	_ui.current_lobby_label.text = "No lobby"


func _on_create_lobby_pressed() -> void:
	var client := _get_client()
	if client:
		client.lobby_create(
			_ui.lobby_name_edit.text.strip_edges(),
			int(_ui.max_players_spin.value),
			{},
			_DEMO_GAME_ID,
			_ui.private_lobby_cb.button_pressed,
		)


func _on_join_pressed() -> void:
	var client := _get_client()
	var lid: String = _ui.lobby_id_edit.text.strip_edges()
	if client and not lid.is_empty():
		client.lobby_join(lid, _DEMO_GAME_ID, _ui.join_passcode_edit.text.strip_edges())


func _on_leave_pressed() -> void:
	var client := _get_client()
	if client and not _current_lobby_id.is_empty():
		client.lobby_leave(_current_lobby_id)
	_current_lobby_id = ""
	_current_members.clear()
	_clear_multiplayer_3d()
	_refresh_members_list()
	_ui.current_lobby_label.text = "No lobby"
	_update_ui_state()


func _on_refresh_pressed() -> void:
	var client := _get_client()
	if client:
		client.lobby_list(_DEMO_GAME_ID, true)


func _on_lobby_created(lobby_id: String, members: Array, passcode: String = "") -> void:
	_current_lobby_id = lobby_id
	_current_members = members
	if passcode.is_empty():
		_ui.current_lobby_label.text = "Lobby: %s · share ID" % lobby_id
		_ui.append_log("[Lobby created] %s\n" % lobby_id)
	else:
		_ui.current_lobby_label.text = "Lobby: %s · pass %s (private)" % [lobby_id, passcode]
		_ui.append_log("[Lobby created] %s passcode %s\n" % [lobby_id, passcode])
	_ensure_local_player()
	_sync_remote_roster()
	_update_ui_state()


func _on_lobby_joined(lobby_id: String, members: Array) -> void:
	_current_lobby_id = lobby_id
	_current_members = members
	_ui.current_lobby_label.text = "Lobby: %s" % lobby_id
	_refresh_members_list()
	_ui.append_log("[Lobby joined] %s\n" % lobby_id)
	_ensure_local_player()
	_sync_remote_roster()
	_update_ui_state()


func _on_lobby_left(lobby_id: String) -> void:
	_current_lobby_id = ""
	_current_members.clear()
	_clear_multiplayer_3d()
	_refresh_members_list()
	_ui.current_lobby_label.text = "No lobby"
	_ui.append_log("[Lobby left] %s\n" % lobby_id)
	_update_ui_state()


func _on_lobby_member_joined(lobby_id: String, peer_id: int, username: String) -> void:
	if lobby_id != _current_lobby_id:
		return
	_current_members.append({"peer_id": peer_id, "username": username})
	_refresh_members_list()
	_ensure_remote_avatar(peer_id, username)


func _on_lobby_member_left(lobby_id: String, peer_id: int) -> void:
	if lobby_id != _current_lobby_id:
		return
	var next: Array = []
	for m in _current_members:
		if m is Dictionary and int(m.get("peer_id", -1)) != peer_id:
			next.append(m)
	_current_members = next
	_refresh_members_list()
	_destroy_remote_avatar(peer_id)


func _on_lobby_list_received(lobbies: Array) -> void:
	_ui.clear_lobby_list_rows()
	for lob in lobbies:
		if lob is Dictionary:
			var id_str: String = lob.get("lobby_id", "")
			var mc: int = lob.get("member_count", 0)
			var mp: int = lob.get("max_players", 0)
			var name_str: String = lob.get("name", "")
			var display: String = id_str if name_str.is_empty() else "%s — %s" % [name_str, id_str]
			_ui.add_lobby_list_row("%s (%d / %d)" % [display, mc, mp])


func _on_lobby_error(reason: String) -> void:
	_ui.set_status_raw("Lobby error: %s" % reason)
	_ui.append_log("[Error] %s\n" % reason)


func _refresh_members_list() -> void:
	var lines: Array = []
	for m in _current_members:
		if m is Dictionary:
			var pid: int = int(m.get("peer_id", 0))
			var uname: String = m.get("username", "")
			lines.append("%d — %s" % [pid, uname])
	_ui.refresh_members_items(lines)


func _on_send_pressed() -> void:
	var client := _get_client()
	if client == null or not client.is_handshaken():
		return
	var tid_str: String = _ui.target_peer_edit.text.strip_edges()
	if tid_str.is_empty():
		return
	if not tid_str.is_valid_int():
		_ui.append_log("[Error] Invalid peer ID: %s\n" % tid_str)
		return
	var tid := int(tid_str)
	if _ui.send_binary_cb.button_pressed:
		var yaw := float(_ui.message_edit.text.hash() % 360) * 0.01
		var state := {"p": Vector3(0.0, 1.0, -1.0), "y": yaw, "pitch": 0.0}
		var delta := RakiyPack.pack_selective_pose_delta(_last_sent_pose, state)
		_last_sent_pose = state.duplicate(true)
		if delta.is_empty():
			_ui.append_log("[You -> %d] binary: nothing changed\n" % tid)
			return
		client.send_data(tid, RakiyConstants.CHANNEL_UNRELIABLE_GAME, false, delta)
		_ui.append_log("[You -> %d] binary pose (%d bytes)\n" % [tid, delta.size()])
	else:
		var msg: String = _ui.message_edit.text
		client.send_data(tid, RakiyConstants.CHANNEL_RELIABLE_GAME, true, msg)
		_ui.append_log("[You -> %d] %s\n" % [tid, msg])
		_ui.message_edit.clear()


func _on_copy_lobby_id_pressed() -> void:
	if not _current_lobby_id.is_empty():
		DisplayServer.clipboard_set(_current_lobby_id)
		_ui.append_log("[Copied lobby ID to clipboard]\n")


func _on_data_received(peer_id: int, _channel: int, _reliable: bool, payload: Variant) -> void:
	var client := _get_client()
	if client == null or peer_id == client.get_peer_id():
		return
	if payload is PackedByteArray:
		_apply_incoming_pose(peer_id, payload)
	else:
		_ui.append_log("[From %d] %s\n" % [peer_id, payload])
