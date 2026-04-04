extends CanvasLayer
class_name DemoUI
## Rakiy demo HUD: floating tabbed console (Connect [→] Lobby [→] Lab); status pill on the card. See [code]flowchart.md[/code].

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
@onready var collapse_hud_btn: Button = %CollapseHudBtn
@onready var show_hud_btn: Button = %ShowHudBtn
@onready var bottom_area: Control = $Root/BottomArea
@onready var center_c: CenterContainer = $Root/BottomArea/CenterC
@onready var collapsed_strip: Control = $Root/BottomArea/CollapsedStrip

const _BOTTOM_EXPANDED_TOP := -580.0
const _BOTTOM_COLLAPSED_TOP := -68.0

var _hud_collapsed: bool = false


func _ready() -> void:
	set_process_unhandled_input(true)
	collapse_hud_btn.pressed.connect(_on_collapse_hud_pressed)
	show_hud_btn.pressed.connect(_on_expand_hud_pressed)


func is_hud_collapsed() -> bool:
	return _hud_collapsed


func set_hud_collapsed(collapsed: bool) -> void:
	_hud_collapsed = collapsed
	center_c.visible = not collapsed
	collapsed_strip.visible = collapsed
	bottom_area.offset_top = _BOTTOM_COLLAPSED_TOP if collapsed else _BOTTOM_EXPANDED_TOP
	collapse_hud_btn.visible = not collapsed


func _on_collapse_hud_pressed() -> void:
	set_hud_collapsed(true)


func _on_expand_hud_pressed() -> void:
	set_hud_collapsed(false)


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var e := event as InputEventKey
	if not e.pressed or e.echo:
		return
	if e.keycode != KEY_F2:
		return
	var foc: Control = get_viewport().gui_get_focus_owner() as Control
	if foc and (foc is LineEdit or foc is TextEdit):
		return
	set_hud_collapsed(not _hud_collapsed)
	get_viewport().set_input_as_handled()


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
