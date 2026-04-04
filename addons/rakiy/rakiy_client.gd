extends Node

## Rakiy WebSocket client: relay, lobbies, optional [member RakiyP2P] for native WebRTC.
## Register as Autoload (e.g. RakiyClient). This script has no global class_name; use preload for static typing in other scripts.

signal websocket_opened
signal disconnected
signal handshake_ok(peer_id: int)
signal handshake_fail(reason: String)
signal data_received(from_peer_id: int, channel: int, reliable: bool, payload: Variant)
signal lobby_created(lobby_id: String, members: Array, passcode: String)
signal lobby_joined(lobby_id: String, members: Array)
signal lobby_left(lobby_id: String)
signal lobby_list_received(lobbies: Array)
signal lobby_member_joined(lobby_id: String, peer_id: int, username: String, capability: int)
signal lobby_member_left(lobby_id: String, peer_id: int)
signal lobby_error(reason: String)
## Emitted when [member debug] is true: connection state, close codes, handshake lines (for in-editor or UI logs).
signal debug_log(line: String)

@export var debug := false
## `relay` for web export; `p2p` for native (default).
@export var handshake_capability: String = "p2p"
@export var unreliable_send_rate_cap: int = 0
@export var unreliable_send_rate_window_sec: float = 1.0

var _ws: WebSocketPeer = WebSocketPeer.new()
var _url: String = ""
var _username: String = ""
var _peer_id: int = -1
var _handshaken: bool = false
var _p2p: RakiyP2P = null
var _pending_handshake: bool = false
var _ws_state_prev: int = -1
var _socket_open_emitted: bool = false

var _unreliable_window_start: float = 0.0
var _unreliable_sent_in_window: int = 0

## Counters for demo/debug: game payloads only (not WebRTC signaling on the relay).
var _stat_p2p_game_out: int = 0
var _stat_p2p_game_in: int = 0
var _stat_relay_game_out: int = 0
var _stat_relay_game_in: int = 0
var _stat_relay_sig_out: int = 0
var _stat_relay_sig_in: int = 0

func _ready() -> void:
	set_process(true)

func _process(_delta: float) -> void:
	poll()

func is_connected_to_host() -> bool:
	return _ws.get_ready_state() == WebSocketPeer.STATE_OPEN

func is_connecting() -> bool:
	return _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING

func is_handshaken() -> bool:
	return _handshaken

func get_peer_id() -> int:
	return _peer_id

func connect_to_url(url: String, username: String, capability: String = "") -> void:
	disconnect_from_host()
	_url = url
	_username = username
	if capability != "":
		handshake_capability = capability
	_handshaken = false
	_peer_id = -1
	_pending_handshake = true
	_socket_open_emitted = false
	_ws_state_prev = -1
	var err := _ws.connect_to_url(url)
	_dbg("connect_to_url url=%s err=%s (%s)" % [url, err, error_string(err)])
	if err != OK:
		handshake_fail.emit("connect failed: %s" % err)
		_pending_handshake = false
		return
	_dbg("connect_to_url queued (async); poll until STATE_OPEN")

func disconnect_from_host() -> void:
	if _p2p:
		_p2p.cleanup()
	_ws.close()
	_handshaken = false
	_peer_id = -1
	_pending_handshake = false
	_socket_open_emitted = false
	_ws_state_prev = -1
	_reset_transport_stats()

func _reset_transport_stats() -> void:
	_stat_p2p_game_out = 0
	_stat_p2p_game_in = 0
	_stat_relay_game_out = 0
	_stat_relay_game_in = 0
	_stat_relay_sig_out = 0
	_stat_relay_sig_in = 0


## Incremented from [RakiyP2P] when a game packet arrives over a WebRTC data channel.
func record_p2p_game_inbound() -> void:
	_stat_p2p_game_in += 1


func get_transport_stats() -> Dictionary:
	return {
		"p2p_game_in": _stat_p2p_game_in,
		"p2p_game_out": _stat_p2p_game_out,
		"relay_game_in": _stat_relay_game_in,
		"relay_game_out": _stat_relay_game_out,
		"relay_sig_in": _stat_relay_sig_in,
		"relay_sig_out": _stat_relay_sig_out,
		"handshake_capability": handshake_capability,
	}


func get_transport_summary() -> String:
	var n_open := 0
	if _p2p:
		n_open = _p2p.count_open_data_channels()
	var st := get_transport_stats()
	return (
		"cap=%s · webrtc_dc_open=%d · game P2P in/out %d/%d · game relay in/out %d/%d · signaling relay in/out %d/%d"
		% [
			st["handshake_capability"],
			n_open,
			st["p2p_game_in"],
			st["p2p_game_out"],
			st["relay_game_in"],
			st["relay_game_out"],
			st["relay_sig_in"],
			st["relay_sig_out"],
		]
	)

func set_p2p_helper(helper: RakiyP2P) -> void:
	if _p2p and _p2p != helper:
		_p2p.cleanup()
	_p2p = helper
	if _p2p:
		_p2p.attach_client(self)

func poll() -> void:
	_ws.poll()
	var st := _ws.get_ready_state()
	if debug and st != _ws_state_prev:
		var idle_closed: bool = (
			st == WebSocketPeer.STATE_CLOSED
			and _ws_state_prev < 0
			and not _pending_handshake
			and not _handshaken
			and not _socket_open_emitted
		)
		if not idle_closed:
			_dbg("ws state %s -> %s" % [_ws_state_name(_ws_state_prev), _ws_state_name(st)])
		_ws_state_prev = st
	if st == WebSocketPeer.STATE_CLOSED:
		var had_link: bool = _handshaken or _pending_handshake or _socket_open_emitted
		if had_link:
			var cc := _ws.get_close_code()
			var cr := _ws.get_close_reason()
			_dbg("ws closed code=%d reason=%s" % [cc, cr])
			_handshaken = false
			_peer_id = -1
			_pending_handshake = false
			_socket_open_emitted = false
			disconnected.emit()
		return
	if st == WebSocketPeer.STATE_OPEN and not _socket_open_emitted:
		_socket_open_emitted = true
		websocket_opened.emit()
	if st == WebSocketPeer.STATE_OPEN and _pending_handshake and not _handshaken:
		_send_handshake()
		_pending_handshake = false
	if st != WebSocketPeer.STATE_OPEN:
		return
	while _ws.get_available_packet_count() > 0:
		var is_text := _ws.was_string_packet()
		var pkt: PackedByteArray = _ws.get_packet()
		var perr := _ws.get_packet_error()
		if perr != OK:
			_dbg("ws get_packet_error=%s (after get_packet, is_text=%s)" % [error_string(perr), is_text])
			continue
		if is_text:
			_handle_text(pkt.get_string_from_utf8())
			continue
		# Some stacks deliver JSON as binary UTF-8; Godot reports was_string_packet() == false.
		if not _handshaken and pkt.size() > 0 and pkt.size() <= 8192:
			var as_text := pkt.get_string_from_utf8()
			if as_text.length() > 0 and as_text[0] == "{" and _looks_like_handshake_json(as_text):
				_dbg("frame is binary opcode but UTF-8 JSON (handshake path); parsing as text")
				_handle_text(as_text)
				continue
		if debug and not _handshaken and pkt.size() > 0 and pkt.size() <= 64:
			_dbg("binary pre-handshake %d bytes: %s" % [pkt.size(), pkt.hex_encode()])
		_handle_binary(pkt)
	if _p2p:
		_p2p.poll()

func _send_handshake() -> void:
	var o := {"t": "hs", "v": RakiyConstants.PROTOCOL_VERSION, "u": _username}
	if handshake_capability == "relay" or handshake_capability == "p2p":
		o["c"] = handshake_capability
	_dbg("sending handshake %s" % JSON.stringify(o))
	_ws.send_text(JSON.stringify(o))

func _handle_text(t: String) -> void:
	var preview: String = t if t.length() <= 240 else t.substr(0, 240) + "…"
	_dbg("text in: %s" % preview)
	var j = JSON.new()
	if j.parse(t) != OK:
		_dbg("text JSON parse failed")
		return
	var d = j.data
	if typeof(d) != TYPE_DICTIONARY:
		return
	if d.get("t") == "ok" and d.has("p"):
		_peer_id = int(d["p"])
		_handshaken = true
		_dbg("handshake ok peer_id=%d" % _peer_id)
		if _p2p:
			_p2p.on_handshake_ok(_peer_id)
		handshake_ok.emit(_peer_id)
	elif d.get("t") == "fail":
		_dbg("handshake fail: %s" % str(d.get("r", "fail")))
		handshake_fail.emit(str(d.get("r", "fail")))

func _handle_binary(buf: PackedByteArray) -> void:
	if buf.size() < 5:
		return
	var magic := buf.decode_u32(0)
	if magic == RakiyConstants.CONTROL_MAGIC:
		_handle_control(buf)
		return
	if magic != RakiyConstants.RELAY_MAGIC_V1 and magic != RakiyConstants.RELAY_MAGIC_V2:
		return
	var from_peer: int
	var channel: int
	var flags: int
	var payload: PackedByteArray
	if magic == RakiyConstants.RELAY_MAGIC_V2:
		if buf.size() < 14:
			return
		from_peer = buf.decode_u32(4)
		channel = buf.decode_u16(8)
		flags = buf[10]
		var plen := buf.decode_u16(12)
		if buf.size() != 14 + plen:
			return
		payload = buf.slice(14, 14 + plen)
	else:
		if buf.size() < 16:
			return
		from_peer = buf.decode_u32(4)
		channel = buf.decode_u16(8)
		flags = buf[10]
		var plen32 := buf.decode_u32(12)
		if buf.size() != 16 + plen32:
			return
		payload = buf.slice(16, 16 + plen32)
	var reliable := (flags & 1) != 0
	var is_utf8 := (flags & 2) != 0
	if channel == RakiyConstants.CHANNEL_SIGNALING and _p2p:
		_stat_relay_sig_in += 1
		_p2p.on_signaling_incoming(from_peer, payload, is_utf8)
		return
	var out: Variant = payload
	if is_utf8:
		out = payload.get_string_from_utf8()
	if _p2p and _p2p.try_deliver_incoming(from_peer, channel, reliable, out):
		return
	_stat_relay_game_in += 1
	data_received.emit(from_peer, channel, reliable, out)

func _handle_control(buf: PackedByteArray) -> void:
	if buf.size() < 5:
		return
	var op := buf[4]
	var o := 5
	if op == 0x10 or op == 0x11:
		if buf.size() < o + 2:
			return
		var idlen := buf.decode_u16(o)
		o += 2
		if buf.size() < o + idlen:
			return
		var lobby_id := buf.slice(o, o + idlen).get_string_from_utf8()
		o += idlen
		var n := buf[o]
		o += 1
		var members: Array = []
		for _i in n:
			if buf.size() < o + 4 + 2:
				return
			var pid := buf.decode_u32(o)
			o += 4
			var cap := buf[o]
			o += 1
			var ulen := buf[o]
			o += 1
			if buf.size() < o + ulen:
				return
			var uname := buf.slice(o, o + ulen).get_string_from_utf8()
			o += ulen
			members.append({"peer_id": pid, "username": uname, "capability": cap})
		var creator_passcode := ""
		if op == 0x10 and o < buf.size():
			var pclen := buf[o]
			o += 1
			if buf.size() >= o + pclen:
				creator_passcode = buf.slice(o, o + pclen).get_string_from_utf8()
		if op == 0x10:
			lobby_created.emit(lobby_id, members, creator_passcode)
		else:
			lobby_joined.emit(lobby_id, members)
	elif op == 0x12:
		if buf.size() < o + 2:
			return
		var l2 := buf.decode_u16(o)
		o += 2
		var lid := buf.slice(o, o + l2).get_string_from_utf8()
		lobby_left.emit(lid)
	elif op == 0x13:
		var lobbies: Array = []
		if buf.size() < o + 2:
			return
		var count := buf.decode_u16(o)
		o += 2
		for _j in count:
			if buf.size() < o + 6:
				return
			var elen := buf.decode_u16(o)
			o += 2
			var eid := buf.slice(o, o + elen).get_string_from_utf8()
			o += elen
			o += 2
			var nlen := buf.decode_u16(o)
			o += 2
			o += nlen
			lobbies.append({"lobby_id": eid})
		lobby_list_received.emit(lobbies)
	elif op == 0x14:
		if buf.size() < o + 2:
			return
		var l3 := buf.decode_u16(o)
		o += 2
		var lobby_id2 := buf.slice(o, o + l3).get_string_from_utf8()
		o += l3
		var pid2 := buf.decode_u32(o)
		o += 4
		var cap2 := buf[o]
		o += 1
		var ulen2 := buf[o]
		o += 1
		var user2 := buf.slice(o, o + ulen2).get_string_from_utf8()
		lobby_member_joined.emit(lobby_id2, pid2, user2, cap2)
	elif op == 0x15:
		if buf.size() < o + 2:
			return
		var l4 := buf.decode_u16(o)
		o += 2
		var lobby_id3 := buf.slice(o, o + l4).get_string_from_utf8()
		o += l4
		var pid3 := buf.decode_u32(o)
		lobby_member_left.emit(lobby_id3, pid3)
	elif op == 0x1F:
		if buf.size() < o + 2:
			return
		var rl := buf.decode_u16(o)
		o += 2
		var reason := buf.slice(o, o + rl).get_string_from_utf8()
		lobby_error.emit(reason)

func _put_u16_str(sp: StreamPeerBuffer, s: String) -> void:
	var b := s.to_utf8_buffer()
	sp.put_u16(b.size())
	sp.put_data(b)

func lobby_create(p_lobby_name: String, max_players: int, metadata: Dictionary, game_id: String, private_lobby: bool = false) -> void:
	var sp := StreamPeerBuffer.new()
	sp.put_u32(RakiyConstants.CONTROL_MAGIC)
	sp.put_u8(0x01)
	sp.put_u8(max_players & 0xFF)
	_put_u16_str(sp, game_id)
	_put_u16_str(sp, p_lobby_name)
	_put_u16_str(sp, JSON.stringify(metadata))
	if private_lobby:
		sp.put_u8(1)
	_ws.put_packet(sp.get_data_array())

func lobby_join(lobby_id: String, game_id: String, passcode: String = "") -> void:
	var sp := StreamPeerBuffer.new()
	sp.put_u32(RakiyConstants.CONTROL_MAGIC)
	sp.put_u8(0x02)
	_put_u16_str(sp, lobby_id)
	_put_u16_str(sp, game_id)
	if passcode.length() > 0:
		_put_u16_str(sp, passcode)
	_ws.put_packet(sp.get_data_array())

func lobby_leave(lobby_id: String) -> void:
	var sp := StreamPeerBuffer.new()
	sp.put_u32(RakiyConstants.CONTROL_MAGIC)
	sp.put_u8(0x03)
	_put_u16_str(sp, lobby_id)
	_ws.put_packet(sp.get_data_array())

func lobby_list(game_id: String, subscribe: bool) -> void:
	var sp := StreamPeerBuffer.new()
	sp.put_u32(RakiyConstants.CONTROL_MAGIC)
	sp.put_u8(0x04)
	var flags := 0
	if subscribe:
		flags |= 1
	if game_id.length() > 0:
		flags |= 2
	sp.put_u8(flags)
	if game_id.length() > 0:
		_put_u16_str(sp, game_id)
	_ws.put_packet(sp.get_data_array())

func send_data(target_peer_id: int, channel: int, reliable: bool, payload: Variant) -> void:
	if not _handshaken:
		return
	if _p2p and channel != RakiyConstants.CHANNEL_SIGNALING:
		if _p2p.try_send_p2p(target_peer_id, channel, reliable, payload):
			_stat_p2p_game_out += 1
			return
	if unreliable_send_rate_cap > 0 and channel == RakiyConstants.CHANNEL_UNRELIABLE_GAME and not reliable:
		var now := Time.get_ticks_msec() / 1000.0
		if now - _unreliable_window_start > unreliable_send_rate_window_sec:
			_unreliable_window_start = now
			_unreliable_sent_in_window = 0
		if _unreliable_sent_in_window >= unreliable_send_rate_cap:
			return
		_unreliable_sent_in_window += 1
	var pl: PackedByteArray
	var utf8_flag := false
	if typeof(payload) == TYPE_STRING:
		pl = str(payload).to_utf8_buffer()
		utf8_flag = true
	else:
		pl = payload
	var flags := 1 if reliable else 0
	if utf8_flag:
		flags |= 2
	var out := PackedByteArray()
	if pl.size() <= 65535:
		out.resize(14 + pl.size())
		out.encode_u32(0, RakiyConstants.RELAY_MAGIC_V2)
		out.encode_u32(4, target_peer_id)
		out.encode_u16(8, channel)
		out[10] = flags
		out[11] = 0
		out.encode_u16(12, pl.size())
		for i in pl.size():
			out[14 + i] = pl[i]
	else:
		out.resize(16 + pl.size())
		out.encode_u32(0, RakiyConstants.RELAY_MAGIC_V1)
		out.encode_u32(4, target_peer_id)
		out.encode_u16(8, channel)
		out[10] = flags
		out[11] = 0
		out.encode_u32(12, pl.size())
		for i in pl.size():
			out[16 + i] = pl[i]
	if channel == RakiyConstants.CHANNEL_SIGNALING:
		_stat_relay_sig_out += 1
	else:
		_stat_relay_game_out += 1
	_ws.put_packet(out)

func send_lobby_broadcast(channel: int, reliable: bool, payload: Variant) -> void:
	send_data(RakiyConstants.TARGET_LOBBY_BROADCAST, channel, reliable, payload)

func flush_pending_sends() -> void:
	pass


func _looks_like_handshake_json(s: String) -> bool:
	if s.length() < 8 or s.length() > 8192:
		return false
	return s[0] == "{" and s.contains("\"t\"")


func _dbg(line: String) -> void:
	if not debug:
		return
	print("[Rakiy] ", line)
	debug_log.emit(line)


func _ws_state_name(s: int) -> String:
	if s < 0:
		return "—"
	if s == WebSocketPeer.STATE_CONNECTING:
		return "CONNECTING"
	if s == WebSocketPeer.STATE_OPEN:
		return "OPEN"
	if s == WebSocketPeer.STATE_CLOSING:
		return "CLOSING"
	if s == WebSocketPeer.STATE_CLOSED:
		return "CLOSED"
	return "state(%d)" % s
