class_name RakiyClientNode
extends Node

## Rakiy WebSocket client: handshake, data frames by peer ID, and lobbies.
## Use as Autoload (Project → Project Settings → Autoload, path to this script) or add as child node.
## Poll every frame: call poll() from _process() (or use the node's _process when added to tree).

@export var debug: bool = false

const PROTOCOL_VERSION := 1
const HANDSHAKE_TIMEOUT_SEC := 10.0

signal websocket_opened
signal disconnected
signal handshake_ok(peer_id: int)
signal handshake_fail(reason: String)
signal data_received(peer_id: int, channel: int, reliable: bool, payload: Variant)
signal lobby_created(lobby_id: String, members: Array)
signal lobby_joined(lobby_id: String, members: Array)
signal lobby_left(lobby_id: String)
signal lobby_list_received(lobbies: Array)
## Emitted when the server pushes an updated member list for a lobby (reactive sync).
signal lobby_members_updated(lobby_id: String, members: Array)
signal lobby_error(reason: String)

var _ws: WebSocketPeer
var _peer_id: int = -1
var _handshaken: bool = false
var _pending_username: String = ""
var _pending_url: String = ""
var _handshake_elapsed: float = -1.0

func _ready() -> void:
	_ws = WebSocketPeer.new()
	set_process(false)


func _process(delta: float) -> void:
	if _handshake_elapsed >= 0.0 and not _handshaken:
		_handshake_elapsed += delta
		if _handshake_elapsed >= HANDSHAKE_TIMEOUT_SEC:
			_handshake_elapsed = -1.0
			_fail_connection("Handshake timed out (no response within %d seconds)" % int(HANDSHAKE_TIMEOUT_SEC))
			return
	poll()


func _log(msg: String) -> void:
	if debug:
		print("[Rakiy] ", msg)


## Call every frame to process incoming packets. If this node is in the tree, _process does it automatically.
func poll() -> void:
	if _ws == null:
		return
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		_ws.poll()
		var code := _ws.get_close_code()
		while _ws.get_available_packet_count() > 0:
			var packet := _ws.get_packet()
			var text := packet.get_string_from_utf8()
			if text.is_empty():
				continue
			_handle_message(text)
		if code != -1:
			_log("Connection closed by peer, code=%s" % code)
			_close_connection()
			return
	elif state == WebSocketPeer.STATE_CLOSING:
		_ws.poll()
		if _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_log("WebSocket STATE_CLOSED")
			_close_connection()
	elif not _pending_url.is_empty() and state != WebSocketPeer.STATE_OPEN:
		_ws.poll()
		var new_state := _ws.get_ready_state()
		if new_state == WebSocketPeer.STATE_OPEN:
			_log("WebSocket opened, sending handshake")
			_send_handshake()
		elif new_state == WebSocketPeer.STATE_CLOSED:
			_log("WebSocket failed to connect (state=CLOSED)")
			_fail_connection("Connection failed or refused. Is the server running?")


func _close_connection() -> void:
	_log("Closing connection (peer_id was %d)" % _peer_id)
	if _ws != null:
		_ws.close()
	_peer_id = -1
	_handshaken = false
	_pending_url = ""
	_pending_username = ""
	_handshake_elapsed = -1.0
	set_process(false)
	disconnected.emit()


func _fail_connection(reason: String) -> void:
	_log("Connection failed: %s" % reason)
	if _ws != null:
		_ws.close()
	_ws = WebSocketPeer.new()
	_peer_id = -1
	_handshaken = false
	_pending_url = ""
	_pending_username = ""
	_handshake_elapsed = -1.0
	set_process(false)
	handshake_fail.emit(reason)
	push_error("[Rakiy] %s" % reason)


func _send_handshake() -> void:
	var msg := {
		"type": "handshake",
		"username": _pending_username,
		"version": PROTOCOL_VERSION
	}
	var body := JSON.stringify(msg)
	_log("Sending handshake: %s" % body)
	var err := _ws.send_text(body)
	if err != OK:
		_log("send_text failed during handshake: %s" % error_string(err))
	_handshake_elapsed = 0.0
	websocket_opened.emit()


func _handle_message(text: String) -> void:
	_log("Received: %s" % text.substr(0, 200) + ("..." if text.length() > 200 else ""))
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		_log("JSON parse error: %s for: %s" % [error_string(err), text.substr(0, 100)])
		return
	var data: Variant = json.get_data()
	if data == null or typeof(data) != TYPE_DICTIONARY:
		_log("Message is not a dictionary")
		return
	var msg: Dictionary = data
	var msg_type: String = msg.get("type", "")
	if msg_type == "handshake_ok":
		_handshaken = true
		_handshake_elapsed = -1.0
		_peer_id = int(msg.get("peer_id", -1))
		_log("Handshake OK, peer_id=%d" % _peer_id)
		handshake_ok.emit(_peer_id)
	elif msg_type == "handshake_fail":
		var reason: String = str(msg.get("reason", "Unknown"))
		_log("Handshake FAIL: %s" % reason)
		push_error("[Rakiy] Handshake failed: %s" % reason)
		handshake_fail.emit(reason)
	elif msg_type == "lobby_created":
		lobby_created.emit(str(msg.get("lobby_id", "")), _members_array(msg))
	elif msg_type == "lobby_joined":
		lobby_joined.emit(str(msg.get("lobby_id", "")), _members_array(msg))
	elif msg_type == "lobby_left":
		lobby_left.emit(str(msg.get("lobby_id", "")))
	elif msg_type == "lobby_list":
		lobby_list_received.emit(msg.get("lobbies", []))
	elif msg_type == "lobby_members_updated":
		lobby_members_updated.emit(str(msg.get("lobby_id", "")), _members_array(msg))
	elif msg_type == "lobby_error":
		lobby_error.emit(str(msg.get("reason", "Unknown")))
	elif msg.has("from_peer_id") and msg.has("channel") and msg.has("payload"):
		var from_id: int = int(msg.get("from_peer_id", -1))
		var channel: int = int(msg.get("channel", 0))
		var reliable: bool = bool(msg.get("reliable", true))
		var payload_var: Variant = msg.get("payload", "")
		data_received.emit(from_id, channel, reliable, payload_var)


func _members_array(msg: Dictionary) -> Array:
	var arr: Array = msg.get("members", [])
	var out: Array = []
	for m in arr:
		if m is Dictionary:
			out.append(m)
	return out


## Connect to URL (e.g. ws://127.0.0.1:3000/ or wss://your-domain/) and send handshake with username.
## For local dev with Godot, use ws://127.0.0.1:port/ instead of localhost to avoid a ~30s connect delay (engine IPv6 timeout).
func connect_to_url(url: String, username: String) -> void:
	_log("connect_to_url(%s, %s)" % [url, username])
	disconnect_from_host()
	_ws = WebSocketPeer.new()
	_pending_url = url
	_pending_username = username
	var err := _ws.connect_to_url(url)
	if err != OK:
		var err_msg := "Connect failed: %s" % error_string(err)
		_log(err_msg)
		push_error("[Rakiy] %s" % err_msg)
		handshake_fail.emit(err_msg)
		_pending_url = ""
		_pending_username = ""
		return
	set_process(true)
	_log("connect_to_url returned OK, state=%s (CONNECTING=%s)" % [_ws.get_ready_state(), WebSocketPeer.STATE_CONNECTING])


## Close the WebSocket. You get a new peer_id after reconnecting.
func disconnect_from_host() -> void:
	if _ws != null:
		_ws.close()
	_peer_id = -1
	_handshaken = false
	_pending_url = ""
	_pending_username = ""
	_handshake_elapsed = -1.0
	set_process(false)


func is_connected_to_host() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


## True when a connection attempt is in progress (after connect_to_url, before handshake_ok or handshake_fail).
func is_connecting() -> bool:
	return not _pending_url.is_empty() and not _handshaken


func is_handshaken() -> bool:
	return _handshaken


func get_peer_id() -> int:
	return _peer_id


## Send payload to another peer. Payload can be String (sent as-is) or PackedByteArray (sent as base64).
## Only call after handshake_ok. Drops if not handshaken.
func send_data(target_peer_id: int, channel: int, reliable: bool, payload: Variant) -> void:
	if not _handshaken or _ws == null or not is_connected_to_host():
		return
	var payload_str: String
	if payload is PackedByteArray:
		payload_str = Marshalls.raw_to_base64(payload as PackedByteArray)
	else:
		payload_str = str(payload)
	var msg := {
		"target_peer_id": target_peer_id,
		"channel": channel,
		"reliable": reliable,
		"payload": payload_str
	}
	var err := _ws.send_text(JSON.stringify(msg))
	if err != OK:
		_log("send_data failed: %s" % error_string(err))


## Create a lobby. Response via lobby_created or lobby_error.
## Pass game_id so this lobby is only listed when clients call lobby_list(game_id). Use the same game_id for all lobbies of this game.
func lobby_create(name_: String = "", max_players: int = 4, metadata: Dictionary = {}, game_id: String = "") -> void:
	if not _handshaken or _ws == null:
		return
	var msg: Dictionary = {"type": "lobby_create", "max_players": max_players}
	if not game_id.is_empty():
		msg["game_id"] = game_id
	if not name_.is_empty():
		msg["name"] = name_
	if not metadata.is_empty():
		msg["metadata"] = metadata
	var err := _ws.send_text(JSON.stringify(msg))
	if err != OK:
		_log("lobby_create send failed: %s" % error_string(err))


## Join a lobby by ID. Response via lobby_joined or lobby_error.
func lobby_join(lobby_id: String) -> void:
	if not _handshaken or _ws == null:
		return
	var err := _ws.send_text(JSON.stringify({"type": "lobby_join", "lobby_id": lobby_id}))
	if err != OK:
		_log("lobby_join send failed: %s" % error_string(err))


## Leave the given lobby. Response via lobby_left.
func lobby_leave(lobby_id: String) -> void:
	if not _handshaken or _ws == null:
		return
	var err := _ws.send_text(JSON.stringify({"type": "lobby_leave", "lobby_id": lobby_id}))
	if err != OK:
		_log("lobby_leave send failed: %s" % error_string(err))


## Request list of lobbies. Response via lobby_list_received.
## Pass game_id to only list lobbies for that game (same string used in lobby_create). Omit or use "" to list all lobbies (e.g. legacy).
## When subscribe is true and game_id is set, you will receive ongoing lobby_list_received pushes when lobbies change (reactive list).
func lobby_list(game_id: String = "", subscribe: bool = false) -> void:
	if not _handshaken or _ws == null:
		return
	var msg: Dictionary = {"type": "lobby_list"}
	if not game_id.is_empty():
		msg["game_id"] = game_id
	if subscribe:
		msg["subscribe"] = true
	var err := _ws.send_text(JSON.stringify(msg))
	if err != OK:
		_log("lobby_list send failed: %s" % error_string(err))
