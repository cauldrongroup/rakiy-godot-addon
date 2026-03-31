extends Node3D

## Rakiy demo: lobby UI + 3D arena with FPS movement and RakiyPack pose sync (unreliable channel).

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

func _demo_log(msg: String) -> void:
	if _debug:
		print("[Rakiy Demo] ", msg)

var _world_root: Node3D
var _players_root: Node3D

var _url_edit: LineEdit
var _username_edit: LineEdit
var _connect_btn: Button
var _disconnect_btn: Button
var _status_label: Label

var _lobby_name_edit: LineEdit
var _max_players_spin: SpinBox
var _private_lobby_cb: CheckBox
var _create_btn: Button
var _lobby_id_edit: LineEdit
var _join_passcode_edit: LineEdit
var _join_btn: Button
var _leave_btn: Button
var _refresh_btn: Button
var _lobby_list_container: VBoxContainer
var _current_lobby_label: Label
var _members_list: ItemList

var _target_peer_edit: LineEdit
var _message_edit: LineEdit
var _send_binary_cb: CheckBox
var _send_btn: Button
var _log_text: TextEdit

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

	_world_root = Node3D.new()
	_world_root.name = "World"
	add_child(_world_root)
	_players_root = Node3D.new()
	_players_root.name = "Players"
	_world_root.add_child(_players_root)
	_build_world(_world_root)
	_build_ui()
	_connect_signals()
	_update_ui_state()


func _get_client() -> Node:
	var root := get_tree().root
	var c: Node = root.get_node_or_null("RakiyClient")
	if c != null:
		return c
	return get_node_or_null("RakiyClient")


func _build_world(parent: Node3D) -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.14, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.65)
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, 42.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	parent.add_child(sun)

	var floor_size := Vector3(48.0, 0.5, 48.0)
	var floor_body := StaticBody3D.new()
	floor_body.position = Vector3(0.0, -0.25, 0.0)
	var floor_mesh := MeshInstance3D.new()
	var box_m := BoxMesh.new()
	box_m.size = floor_size
	floor_mesh.mesh = box_m
	var mat_f := StandardMaterial3D.new()
	mat_f.albedo_color = Color(0.32, 0.36, 0.4)
	floor_mesh.material_override = mat_f
	var floor_cs := CollisionShape3D.new()
	var floor_sh := BoxShape3D.new()
	floor_sh.size = floor_size
	floor_cs.shape = floor_sh
	floor_body.add_child(floor_mesh)
	floor_body.add_child(floor_cs)
	parent.add_child(floor_body)

	var wall_h := 3.5
	var wall_t := 0.45
	var half := 24.0
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.38, 0.42, 0.46)
	for w in [
		[Vector3(0.0, wall_h * 0.5, -half), Vector3(floor_size.x, wall_h, wall_t)],
		[Vector3(0.0, wall_h * 0.5, half), Vector3(floor_size.x, wall_h, wall_t)],
		[Vector3(-half, wall_h * 0.5, 0.0), Vector3(wall_t, wall_h, floor_size.z)],
		[Vector3(half, wall_h * 0.5, 0.0), Vector3(wall_t, wall_h, floor_size.z)],
	]:
		var wb := StaticBody3D.new()
		wb.position = w[0]
		var wm := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = w[1]
		wm.mesh = bm
		wm.material_override = wall_mat
		var wcs := CollisionShape3D.new()
		var ws := BoxShape3D.new()
		ws.size = w[1]
		wcs.shape = ws
		wb.add_child(wm)
		wb.add_child(wcs)
		parent.add_child(wb)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)

	var panel := Panel.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	panel.anchor_right = 0.0
	panel.offset_right = 430.0
	layer.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(scroll)

	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 8)
	scroll.add_child(v)

	var hint := Label.new()
	hint.text = "3D arena: WASD move, Space jump, mouse look, Esc frees cursor / click game area to capture. Pose sync: RakiyReplication adaptive Hz (8–24), interest radius %dm, lobby broadcast when all peers relevant else per-peer unicast; RakiyPack deltas + ~2s keyframes; send cap 240/s. Chat uses reliable channel." % int(_INTEREST_RADIUS)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)

	var conn_label := Label.new()
	conn_label.text = "Connection"
	conn_label.add_theme_font_size_override("font_size", 18)
	v.add_child(conn_label)

	var url_row := HBoxContainer.new()
	var url_lbl := Label.new()
	url_lbl.text = "URL:"
	url_row.add_child(url_lbl)
	_url_edit = LineEdit.new()
	_url_edit.custom_minimum_size.x = 280
	_url_edit.text = "ws://127.0.0.1:3000/"
	url_row.add_child(_url_edit)
	v.add_child(url_row)

	var user_row := HBoxContainer.new()
	var user_lbl := Label.new()
	user_lbl.text = "Username:"
	user_row.add_child(user_lbl)
	_username_edit = LineEdit.new()
	_username_edit.custom_minimum_size.x = 180
	_username_edit.text = "Player1"
	_username_edit.placeholder_text = "Your name"
	user_row.add_child(_username_edit)
	v.add_child(user_row)

	var btn_row := HBoxContainer.new()
	_connect_btn = Button.new()
	_connect_btn.text = "Connect"
	_connect_btn.pressed.connect(_on_connect_pressed)
	btn_row.add_child(_connect_btn)
	_disconnect_btn = Button.new()
	_disconnect_btn.text = "Disconnect"
	_disconnect_btn.pressed.connect(_on_disconnect_pressed)
	btn_row.add_child(_disconnect_btn)
	v.add_child(btn_row)

	_status_label = Label.new()
	_status_label.text = "Disconnected"
	v.add_child(_status_label)

	v.add_child(HSeparator.new())

	var lobby_label := Label.new()
	lobby_label.text = "Lobby"
	lobby_label.add_theme_font_size_override("font_size", 18)
	v.add_child(lobby_label)

	var create_row := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = "Name:"
	create_row.add_child(name_lbl)
	_lobby_name_edit = LineEdit.new()
	_lobby_name_edit.placeholder_text = "Optional"
	_lobby_name_edit.custom_minimum_size.x = 100
	create_row.add_child(_lobby_name_edit)
	var max_lbl := Label.new()
	max_lbl.text = "Max:"
	create_row.add_child(max_lbl)
	_max_players_spin = SpinBox.new()
	_max_players_spin.min_value = 2
	_max_players_spin.max_value = 16
	_max_players_spin.value = 4
	create_row.add_child(_max_players_spin)
	_private_lobby_cb = CheckBox.new()
	_private_lobby_cb.text = "Private"
	_private_lobby_cb.tooltip_text = "Hidden from lobby list; server assigns a 4-digit passcode for join."
	create_row.add_child(_private_lobby_cb)
	_create_btn = Button.new()
	_create_btn.text = "Create Lobby"
	_create_btn.pressed.connect(_on_create_lobby_pressed)
	create_row.add_child(_create_btn)
	v.add_child(create_row)

	var join_row := HBoxContainer.new()
	var lid_lbl := Label.new()
	lid_lbl.text = "Lobby ID:"
	join_row.add_child(lid_lbl)
	_lobby_id_edit = LineEdit.new()
	_lobby_id_edit.placeholder_text = "Paste lobby ID to join"
	_lobby_id_edit.custom_minimum_size.x = 200
	join_row.add_child(_lobby_id_edit)
	var pc_lbl := Label.new()
	pc_lbl.text = "Pass:"
	join_row.add_child(pc_lbl)
	_join_passcode_edit = LineEdit.new()
	_join_passcode_edit.placeholder_text = "4-digit (if private)"
	_join_passcode_edit.custom_minimum_size.x = 72
	join_row.add_child(_join_passcode_edit)
	_join_btn = Button.new()
	_join_btn.text = "Join"
	_join_btn.pressed.connect(_on_join_pressed)
	join_row.add_child(_join_btn)
	_leave_btn = Button.new()
	_leave_btn.text = "Leave"
	_leave_btn.pressed.connect(_on_leave_pressed)
	join_row.add_child(_leave_btn)
	_refresh_btn = Button.new()
	_refresh_btn.text = "Refresh list"
	_refresh_btn.pressed.connect(_on_refresh_pressed)
	join_row.add_child(_refresh_btn)
	v.add_child(join_row)

	var lobby_row := HBoxContainer.new()
	_current_lobby_label = Label.new()
	_current_lobby_label.text = "Current lobby: (none)"
	_current_lobby_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lobby_row.add_child(_current_lobby_label)
	var copy_btn := Button.new()
	copy_btn.text = "Copy lobby ID"
	copy_btn.pressed.connect(_on_copy_lobby_id_pressed)
	lobby_row.add_child(copy_btn)
	v.add_child(lobby_row)

	var members_label := Label.new()
	members_label.text = "Members (peer_id, username):"
	v.add_child(members_label)
	_members_list = ItemList.new()
	_members_list.custom_minimum_size.y = 56
	v.add_child(_members_list)

	var lobby_list_label := Label.new()
	lobby_list_label.text = "Available lobbies:"
	v.add_child(lobby_list_label)
	_lobby_list_container = VBoxContainer.new()
	_lobby_list_container.custom_minimum_size.y = 72
	v.add_child(_lobby_list_container)

	v.add_child(HSeparator.new())

	var data_label := Label.new()
	data_label.text = "Send message (optional)"
	data_label.add_theme_font_size_override("font_size", 18)
	v.add_child(data_label)

	var send_row := HBoxContainer.new()
	var target_lbl := Label.new()
	target_lbl.text = "Target peer_id:"
	send_row.add_child(target_lbl)
	_target_peer_edit = LineEdit.new()
	_target_peer_edit.placeholder_text = "Peer ID"
	_target_peer_edit.custom_minimum_size.x = 64
	send_row.add_child(_target_peer_edit)
	var msg_lbl := Label.new()
	msg_lbl.text = "Message:"
	send_row.add_child(msg_lbl)
	_message_edit = LineEdit.new()
	_message_edit.placeholder_text = "Text chat"
	_message_edit.custom_minimum_size.x = 160
	_message_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	send_row.add_child(_message_edit)
	_send_binary_cb = CheckBox.new()
	_send_binary_cb.text = "Compact binary test"
	_send_binary_cb.tooltip_text = "Send RakiyPack pose delta instead of UTF-8 (manual test)."
	send_row.add_child(_send_binary_cb)
	_send_btn = Button.new()
	_send_btn.text = "Send"
	_send_btn.pressed.connect(_on_send_pressed)
	send_row.add_child(_send_btn)
	v.add_child(send_row)

	var log_label := Label.new()
	log_label.text = "Log:"
	v.add_child(log_label)
	_log_text = TextEdit.new()
	_log_text.custom_minimum_size.y = 100
	_log_text.editable = false
	v.add_child(_log_text)


func _connect_signals() -> void:
	var client := _get_client()
	if client == null:
		_status_label.text = "Error: RakiyClient not found. Add as Autoload."
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
	var uname := _username_edit.text.strip_edges()
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
	_connect_btn.disabled = conn or connecting
	_disconnect_btn.disabled = not conn and not connecting
	_create_btn.disabled = not handshaken or not _current_lobby_id.is_empty()
	_join_btn.disabled = not handshaken
	_leave_btn.disabled = not handshaken or _current_lobby_id.is_empty()
	_refresh_btn.disabled = not handshaken
	_send_btn.disabled = not handshaken
	_url_edit.editable = not conn and not connecting
	_username_edit.editable = not conn and not connecting
	if handshaken and client:
		_status_label.text = "Connected (peer_id %d)" % client.get_peer_id()
	elif connecting:
		_status_label.text = "Connecting..."
	elif conn:
		_status_label.text = "Connected (waiting for handshake...)"
	else:
		_status_label.text = "Disconnected"


func _on_connect_pressed() -> void:
	var client := _get_client()
	if client == null:
		_status_label.text = "Error: RakiyClient not found."
		return
	client.connect_to_url(_url_edit.text.strip_edges(), _username_edit.text.strip_edges())
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
	_current_lobby_label.text = "Current lobby: (none)"


func _on_handshake_ok(_peer_id: int) -> void:
	_update_ui_state()
	var client := _get_client()
	if client:
		client.lobby_list(_DEMO_GAME_ID, true)


func _on_handshake_fail(reason: String) -> void:
	_status_label.text = "Handshake failed: %s" % reason
	_update_ui_state()


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
	_current_lobby_label.text = "Current lobby: (none)"


func _on_create_lobby_pressed() -> void:
	var client := _get_client()
	if client:
		client.lobby_create(_lobby_name_edit.text.strip_edges(), int(_max_players_spin.value), {}, _DEMO_GAME_ID, _private_lobby_cb.button_pressed)


func _on_join_pressed() -> void:
	var client := _get_client()
	var lid := _lobby_id_edit.text.strip_edges()
	if client and not lid.is_empty():
		client.lobby_join(lid, _DEMO_GAME_ID, _join_passcode_edit.text.strip_edges())


func _on_leave_pressed() -> void:
	var client := _get_client()
	if client and not _current_lobby_id.is_empty():
		client.lobby_leave(_current_lobby_id)
	_current_lobby_id = ""
	_current_members.clear()
	_clear_multiplayer_3d()
	_refresh_members_list()
	_current_lobby_label.text = "Current lobby: (none)"
	_update_ui_state()


func _on_refresh_pressed() -> void:
	var client := _get_client()
	if client:
		client.lobby_list(_DEMO_GAME_ID, true)


func _on_lobby_created(lobby_id: String, members: Array, passcode: String = "") -> void:
	_current_lobby_id = lobby_id
	_current_members = members
	if passcode.is_empty():
		_current_lobby_label.text = "Current lobby: %s (copy ID to share)" % lobby_id
		_log_text.text += "[Lobby created] %s\n" % lobby_id
	else:
		_current_lobby_label.text = "Current lobby: %s — pass %s (not listed)" % [lobby_id, passcode]
		_log_text.text += "[Lobby created] %s passcode %s\n" % [lobby_id, passcode]
	_ensure_local_player()
	_sync_remote_roster()
	_update_ui_state()


func _on_lobby_joined(lobby_id: String, members: Array) -> void:
	_current_lobby_id = lobby_id
	_current_members = members
	_current_lobby_label.text = "Current lobby: %s" % lobby_id
	_refresh_members_list()
	_log_text.text += "[Lobby joined] %s\n" % lobby_id
	_ensure_local_player()
	_sync_remote_roster()
	_update_ui_state()


func _on_lobby_left(lobby_id: String) -> void:
	_current_lobby_id = ""
	_current_members.clear()
	_clear_multiplayer_3d()
	_refresh_members_list()
	_current_lobby_label.text = "Current lobby: (none)"
	_log_text.text += "[Lobby left] %s\n" % lobby_id
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
	for c in _lobby_list_container.get_children():
		c.queue_free()
	for lob in lobbies:
		if lob is Dictionary:
			var id_str: String = lob.get("lobby_id", "")
			var mc: int = lob.get("member_count", 0)
			var mp: int = lob.get("max_players", 0)
			var name_str: String = lob.get("name", "")
			var display: String = id_str if name_str.is_empty() else "%s - %s" % [name_str, id_str]
			var l := Label.new()
			l.text = "%s (%d / %d)" % [display, mc, mp]
			_lobby_list_container.add_child(l)


func _on_lobby_error(reason: String) -> void:
	_status_label.text = "Lobby error: %s" % reason
	_log_text.text += "[Error] %s\n" % reason


func _refresh_members_list() -> void:
	_members_list.clear()
	for m in _current_members:
		if m is Dictionary:
			var pid: int = int(m.get("peer_id", 0))
			var uname: String = m.get("username", "")
			_members_list.add_item("%d - %s" % [pid, uname])


func _on_send_pressed() -> void:
	var client := _get_client()
	if client == null or not client.is_handshaken():
		return
	var tid_str := _target_peer_edit.text.strip_edges()
	if tid_str.is_empty():
		return
	if not tid_str.is_valid_int():
		_log_text.text += "[Error] Invalid peer ID: %s\n" % tid_str
		return
	var tid := int(tid_str)
	if _send_binary_cb.button_pressed:
		var yaw := float(_message_edit.text.hash() % 360) * 0.01
		var state := {"p": Vector3(0.0, 1.0, -1.0), "y": yaw, "pitch": 0.0}
		var delta := RakiyPack.pack_selective_pose_delta(_last_sent_pose, state)
		_last_sent_pose = state.duplicate(true)
		if delta.is_empty():
			_log_text.text += "[You -> %d] binary: nothing changed\n" % tid
			return
		client.send_data(tid, RakiyConstants.CHANNEL_UNRELIABLE_GAME, false, delta)
		_log_text.text += "[You -> %d] binary pose (%d bytes)\n" % [tid, delta.size()]
	else:
		var msg := _message_edit.text
		client.send_data(tid, RakiyConstants.CHANNEL_RELIABLE_GAME, true, msg)
		_log_text.text += "[You -> %d] %s\n" % [tid, msg]
		_message_edit.clear()


func _on_copy_lobby_id_pressed() -> void:
	if not _current_lobby_id.is_empty():
		DisplayServer.clipboard_set(_current_lobby_id)
		_log_text.text += "[Copied lobby ID to clipboard]\n"


func _on_data_received(peer_id: int, _channel: int, _reliable: bool, payload: Variant) -> void:
	var client := _get_client()
	if client == null or peer_id == client.get_peer_id():
		return
	if payload is PackedByteArray:
		_apply_incoming_pose(peer_id, payload)
	else:
		_log_text.text += "[From %d] %s\n" % [peer_id, payload]
