extends CanvasLayer
class_name DemoUI
## Rakiy demo HUD: Connect → Lobby → Lab. In a lobby, UI hides for gameplay; Esc opens pause (same panel + dim).

@onready var main_tabs: TabContainer = %MainTabs
@onready var url_edit: LineEdit = %UrlEdit
@onready var username_edit: LineEdit = %UsernameEdit
@onready var connect_btn: Button = %ConnectBtn
@onready var disconnect_btn: Button = %DisconnectBtn
@onready var status_label: Label = %StatusLabel
@onready var lobby_name_edit: LineEdit = %LobbyNameEdit
@onready var max_players_spin: SpinBox = %MaxPlayersSpin
@onready var private_lobby_cb: CheckBox = %PrivateLobbyCb
@onready var create_btn: Button = %CreateBtn
@onready var lobby_id_edit: LineEdit = %LobbyIdEdit
@onready var join_passcode_edit: LineEdit = %JoinPasscodeEdit
@onready var join_btn: Button = %JoinBtn
@onready var leave_btn: Button = %LeaveBtn
@onready var refresh_btn: Button = %RefreshBtn
@onready var current_lobby_label: Label = %CurrentLobbyLabel
@onready var copy_lobby_id_btn: Button = %CopyLobbyIdBtn
@onready var members_list: ItemList = %MembersList
@onready var lobby_list_container: VBoxContainer = %LobbyListContainer
@onready var target_peer_edit: LineEdit = %TargetPeerEdit
@onready var message_edit: LineEdit = %MessageEdit
@onready var send_binary_cb: CheckBox = %SendBinaryCb
@onready var send_btn: Button = %SendBtn
@onready var log_text: TextEdit = %LogText
@onready var resume_game_btn: Button = %ResumeGameBtn
@onready var pause_dim: ColorRect = $Root/PauseDim
@onready var bottom_area: Control = $Root/BottomArea
@onready var center_c: CenterContainer = $Root/BottomArea/CenterC

const _BOTTOM_EXPANDED_TOP := -580.0

## True after create/join lobby until leave or disconnect.
var _in_lobby_session: bool = false
## True when Esc pause menu is showing (only meaningful if [member _in_lobby_session]).
var _pause_menu_open: bool = false


func _ready() -> void:
	resume_game_btn.pressed.connect(_on_resume_game_pressed)


func enter_lobby_session() -> void:
	_in_lobby_session = true
	_pause_menu_open = false
	_apply_session_state()


func leave_lobby_session() -> void:
	_in_lobby_session = false
	_pause_menu_open = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_apply_session_state()


func is_in_lobby_session() -> bool:
	return _in_lobby_session


func is_pause_menu_open() -> bool:
	return _pause_menu_open


func toggle_pause_menu() -> void:
	if not _in_lobby_session:
		return
	_pause_menu_open = not _pause_menu_open
	if _pause_menu_open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply_session_state()


func close_pause_menu() -> void:
	if not _pause_menu_open:
		return
	_pause_menu_open = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply_session_state()


func _on_resume_game_pressed() -> void:
	close_pause_menu()


func _apply_session_state() -> void:
	resume_game_btn.visible = _pause_menu_open and _in_lobby_session
	if not _in_lobby_session:
		pause_dim.visible = false
		bottom_area.visible = true
		center_c.visible = true
		bottom_area.offset_top = _BOTTOM_EXPANDED_TOP
		return
	if _pause_menu_open:
		pause_dim.visible = true
		bottom_area.visible = true
		center_c.visible = true
		bottom_area.offset_top = _BOTTOM_EXPANDED_TOP
	else:
		pause_dim.visible = false
		bottom_area.visible = false


func apply_connection_state(
	conn: bool,
	handshaken: bool,
	connecting: bool,
	peer_id: int,
	in_lobby: bool,
) -> void:
	connect_btn.disabled = conn or connecting
	disconnect_btn.disabled = not conn and not connecting
	create_btn.disabled = not handshaken or in_lobby
	join_btn.disabled = not handshaken
	leave_btn.disabled = not handshaken or not in_lobby
	refresh_btn.disabled = not handshaken
	send_btn.disabled = not handshaken
	url_edit.editable = not conn and not connecting
	username_edit.editable = not conn and not connecting
	main_tabs.set_tab_disabled(1, not handshaken)
	main_tabs.set_tab_disabled(2, not handshaken)
	if not handshaken:
		main_tabs.current_tab = 0
	if handshaken:
		status_label.text = "Online · peer %d" % peer_id
	elif connecting:
		status_label.text = "Connecting…"
	elif conn:
		status_label.text = "Handshake…"
	else:
		status_label.text = "Offline"


func go_to_lobby_tab() -> void:
	main_tabs.current_tab = 1


func set_status_raw(text: String) -> void:
	status_label.text = text


func append_log(line: String) -> void:
	log_text.text += line


func clear_lobby_list_rows() -> void:
	for c in lobby_list_container.get_children():
		c.queue_free()


func add_lobby_list_row(display_text: String) -> void:
	var l := Label.new()
	l.text = display_text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.72, 0.76, 0.84))
	lobby_list_container.add_child(l)


func refresh_members_items(lines: Array) -> void:
	members_list.clear()
	for s in lines:
		members_list.add_item(str(s))
