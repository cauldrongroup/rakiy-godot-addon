extends Control

## Full Rakiy demo: connect, handshake, lobby create/join/leave/list, send/receive data.
## Uses RakiyClient autoload when present; otherwise adds the client as a child node.

const _RakiyClientScript := preload("res://addons/rakiy/rakiy_client.gd")

## Same game_id for create and list so this demo only sees its own lobbies when multiple games share the server.
const _DEMO_GAME_ID := "rakiy_demo"

var _debug := true

func _demo_log(msg: String) -> void:
	if _debug:
		print("[Rakiy Demo] ", msg)

# Connection
var _url_edit: LineEdit
var _username_edit: LineEdit
var _connect_btn: Button
var _disconnect_btn: Button
var _status_label: Label

# Lobby
var _lobby_name_edit: LineEdit
var _max_players_spin: SpinBox
var _create_btn: Button
var _lobby_id_edit: LineEdit
var _join_btn: Button
var _leave_btn: Button
var _refresh_btn: Button
var _lobby_list_container: VBoxContainer
var _current_lobby_label: Label
var _members_list: ItemList

# Data
var _target_peer_edit: LineEdit
var _message_edit: LineEdit
var _send_btn: Button
var _log_text: TextEdit

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
	_build_ui()
	_connect_signals()
	_update_ui_state()


func _get_client() -> Node:
	var root := get_tree().root
	var c: Node = root.get_node_or_null("RakiyClient")
	if c != null:
		return c
	return get_node_or_null("RakiyClient")


func _build_ui() -> void:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 8)
	add_child(v)

	# Connection panel
	var conn_label := Label.new()
	conn_label.text = "Connection"
	conn_label.add_theme_font_size_override("font_size", 18)
	v.add_child(conn_label)

	var url_row := HBoxContainer.new()
	var url_lbl := Label.new()
	url_lbl.text = "URL:"
	url_row.add_child(url_lbl)
	_url_edit = LineEdit.new()
	_url_edit.custom_minimum_size.x = 320
	_url_edit.text = "ws://127.0.0.1:3000/"
	url_row.add_child(_url_edit)
	v.add_child(url_row)

	var user_row := HBoxContainer.new()
	var user_lbl := Label.new()
	user_lbl.text = "Username:"
	user_row.add_child(user_lbl)
	_username_edit = LineEdit.new()
	_username_edit.custom_minimum_size.x = 200
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

	var sep := HSeparator.new()
	v.add_child(sep)

	# Lobby panel
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
	_lobby_name_edit.custom_minimum_size.x = 120
	create_row.add_child(_lobby_name_edit)
	var max_lbl := Label.new()
	max_lbl.text = "Max:"
	create_row.add_child(max_lbl)
	_max_players_spin = SpinBox.new()
	_max_players_spin.min_value = 2
	_max_players_spin.max_value = 16
	_max_players_spin.value = 4
	create_row.add_child(_max_players_spin)
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
	_lobby_id_edit.custom_minimum_size.x = 220
	join_row.add_child(_lobby_id_edit)
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
	_members_list.custom_minimum_size.y = 60
	v.add_child(_members_list)

	var lobby_list_label := Label.new()
	lobby_list_label.text = "Available lobbies:"
	v.add_child(lobby_list_label)
	_lobby_list_container = VBoxContainer.new()
	_lobby_list_container.custom_minimum_size.y = 80
	v.add_child(_lobby_list_container)

	var sep2 := HSeparator.new()
	v.add_child(sep2)

	# Data panel
	var data_label := Label.new()
	data_label.text = "Send message"
	data_label.add_theme_font_size_override("font_size", 18)
	v.add_child(data_label)

	var send_row := HBoxContainer.new()
	var target_lbl := Label.new()
	target_lbl.text = "Target peer_id:"
	send_row.add_child(target_lbl)
	_target_peer_edit = LineEdit.new()
	_target_peer_edit.placeholder_text = "Peer ID from members"
	_target_peer_edit.custom_minimum_size.x = 80
	send_row.add_child(_target_peer_edit)
	var msg_lbl := Label.new()
	msg_lbl.text = "Message:"
	send_row.add_child(msg_lbl)
	_message_edit = LineEdit.new()
	_message_edit.placeholder_text = "Type message"
	_message_edit.custom_minimum_size.x = 200
	_message_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	send_row.add_child(_message_edit)
	_send_btn = Button.new()
	_send_btn.text = "Send"
	_send_btn.pressed.connect(_on_send_pressed)
	send_row.add_child(_send_btn)
	v.add_child(send_row)

	var log_label := Label.new()
	log_label.text = "Received messages:"
	v.add_child(log_label)
	_log_text = TextEdit.new()
	_log_text.custom_minimum_size.y = 120
	_log_text.editable = false
	v.add_child(_log_text)


func _connect_signals() -> void:
	var client := _get_client()
	if client == null:
		_demo_log("ERROR: _get_client() returned null - RakiyClient autoload or child not found")
		_status_label.text = "Error: RakiyClient not found. Add as Autoload."
		return
	_demo_log("Connected signals to RakiyClient (node: %s)" % client.get_path())
	client.websocket_opened.connect(_on_websocket_opened)
	client.disconnected.connect(_on_disconnected)
	client.handshake_ok.connect(_on_handshake_ok)
	client.handshake_fail.connect(_on_handshake_fail)
	client.lobby_created.connect(_on_lobby_created)
	client.lobby_joined.connect(_on_lobby_joined)
	client.lobby_left.connect(_on_lobby_left)
	client.lobby_list_received.connect(_on_lobby_list_received)
	client.lobby_members_updated.connect(_on_lobby_members_updated)
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
	if client.lobby_members_updated.is_connected(_on_lobby_members_updated):
		client.lobby_members_updated.disconnect(_on_lobby_members_updated)
	if client.lobby_error.is_connected(_on_lobby_error):
		client.lobby_error.disconnect(_on_lobby_error)
	if client.data_received.is_connected(_on_data_received):
		client.data_received.disconnect(_on_data_received)


func _update_ui_state() -> void:
	var client: Node = _get_client()
	var conn: bool = client != null and client.is_connected_to_host()
	var handshaken: bool = client != null and client.is_handshaken()
	var connecting: bool = client != null and client.is_connecting()
	_connect_btn.disabled = conn or connecting
	_disconnect_btn.disabled = not conn and not connecting
	_create_btn.disabled = not handshaken
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
	_demo_log("Connect button pressed")
	var client := _get_client()
	if client == null:
		_demo_log("ERROR: client is null, cannot connect")
		_status_label.text = "Error: RakiyClient not found."
		return
	var url := _url_edit.text.strip_edges()
	var username := _username_edit.text.strip_edges()
	_demo_log("Calling connect_to_url(%s, %s)" % [url, username])
	client.connect_to_url(url, username)
	_update_ui_state()


func _on_disconnect_pressed() -> void:
	var client := _get_client()
	if client:
		client.disconnect_from_host()
	_current_lobby_id = ""
	_current_members.clear()
	_refresh_members_list()
	_update_ui_state()
	_current_lobby_label.text = "Current lobby: (none)"


func _on_handshake_ok(peer_id: int) -> void:
	_demo_log("handshake_ok received, peer_id=%d" % peer_id)
	_update_ui_state()
	var client := _get_client()
	if client:
		client.lobby_list(_DEMO_GAME_ID, true)


func _on_handshake_fail(reason: String) -> void:
	_demo_log("handshake_fail: %s" % reason)
	_status_label.text = "Handshake failed: %s" % reason
	_update_ui_state()


func _process(_delta: float) -> void:
	var client: Node = _get_client()
	if client != null and client.is_connecting():
		_update_ui_state()


func _on_websocket_opened() -> void:
	_demo_log("websocket_opened signal received (handshake sent)")
	_update_ui_state()


func _on_disconnected() -> void:
	_current_lobby_id = ""
	_current_members.clear()
	_refresh_members_list()
	_update_ui_state()
	_current_lobby_label.text = "Current lobby: (none)"


func _on_create_lobby_pressed() -> void:
	var client := _get_client()
	if client:
		client.lobby_create(_lobby_name_edit.text.strip_edges(), int(_max_players_spin.value), {}, _DEMO_GAME_ID)


func _on_join_pressed() -> void:
	var client := _get_client()
	var lid := _lobby_id_edit.text.strip_edges()
	if client and not lid.is_empty():
		client.lobby_join(lid)


func _on_leave_pressed() -> void:
	var client := _get_client()
	if client and not _current_lobby_id.is_empty():
		client.lobby_leave(_current_lobby_id)
		_current_lobby_id = ""
		_current_members.clear()
		_refresh_members_list()
		_current_lobby_label.text = "Current lobby: (none)"


func _on_refresh_pressed() -> void:
	var client := _get_client()
	if client:
		client.lobby_list(_DEMO_GAME_ID, true)


func _on_lobby_created(lobby_id: String, members: Array) -> void:
	_current_lobby_id = lobby_id
	_current_members = members
	_current_lobby_label.text = "Current lobby: %s (copy ID to share)" % lobby_id
	_refresh_members_list()
	_log_text.text += "[Lobby created] %s\n" % lobby_id
	_update_ui_state()


func _on_lobby_joined(lobby_id: String, members: Array) -> void:
	_current_lobby_id = lobby_id
	_current_members = members
	_current_lobby_label.text = "Current lobby: %s" % lobby_id
	_refresh_members_list()
	_log_text.text += "[Lobby joined] %s\n" % lobby_id
	_update_ui_state()


func _on_lobby_left(lobby_id: String) -> void:
	_current_lobby_id = ""
	_current_members.clear()
	_refresh_members_list()
	_current_lobby_label.text = "Current lobby: (none)"
	_log_text.text += "[Lobby left] %s\n" % lobby_id
	_update_ui_state()


func _on_lobby_members_updated(lobby_id: String, members: Array) -> void:
	if lobby_id != _current_lobby_id:
		return
	_current_members = members
	_refresh_members_list()
	_demo_log("Members updated for %s: %d" % [lobby_id, members.size()])


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
		_log_text.text += "[Error] Invalid peer ID: %s (must be a number)\n" % tid_str
		return
	var tid := int(tid_str)
	var msg := _message_edit.text
	client.send_data(tid, RakiyConstants.CHANNEL_RELIABLE_GAME, true, msg)
	_log_text.text += "[You -> %d] %s\n" % [tid, msg]
	_message_edit.clear()


func _on_copy_lobby_id_pressed() -> void:
	if not _current_lobby_id.is_empty():
		DisplayServer.clipboard_set(_current_lobby_id)
		_log_text.text += "[Copied lobby ID to clipboard]\n"


func _on_data_received(peer_id: int, _channel: int, _reliable: bool, payload: Variant) -> void:
	_log_text.text += "[From %d] %s\n" % [peer_id, payload]
