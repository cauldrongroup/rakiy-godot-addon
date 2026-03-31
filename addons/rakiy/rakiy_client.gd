class_name RakiyClientNode
extends Node

## Rakiy WebSocket client v2: compact handshake JSON; game relay + lobby are binary only.

@export var debug: bool = false
## Max unreliable game-channel frames per window (0 = unlimited). Reduces flood / bandwidth spikes.
@export var unreliable_send_rate_cap: int = 0
@export var unreliable_send_rate_window_sec: float = 1.0

const PROTOCOL_VERSION := 2
const HANDSHAKE_TIMEOUT_SEC := 10.0

## Binary relay v1/v2 — multiplayer/src/relay/binary.ts
const RELAY_MAGIC_U32_LE := 0x014B4152
const RELAY_V2_MAGIC_U32_LE := 0x034B4152
const RELAY_HEADER_SIZE := 16
const RELAY_V2_HEADER_SIZE := 14
const RELAY_MAX_PAYLOAD := 524288
const RELAY_V2_MAX_PAYLOAD := 65535
const RELAY_FLAG_RELIABLE := 1
const RELAY_FLAG_UTF8_PAYLOAD := 2

const CHANNEL_UNRELIABLE_GAME := 2

## Lobby/control binary — multiplayer/src/relay/control-binary.ts
const CONTROL_MAGIC_U32_LE := 0x024B4152
const CONTROL_HEADER_SIZE := 5

const OP_CLIENT_CREATE := 0x01
const OP_CLIENT_JOIN := 0x02
const OP_CLIENT_LEAVE := 0x03
const OP_CLIENT_LIST := 0x04
const OP_SRV_CREATED := 0x10
const OP_SRV_JOINED := 0x11
const OP_SRV_LEFT := 0x12
const OP_SRV_LIST := 0x13
const OP_SRV_MEMBER_JOIN := 0x14
const OP_SRV_MEMBER_LEAVE := 0x15
const OP_SRV_ERROR := 0x1F

## Bit 0 of optional create trailing flags (see multiplayer control-binary CREATE_FLAG_PRIVATE).
const CREATE_FLAG_PRIVATE := 1

signal websocket_opened
signal disconnected
signal handshake_ok(peer_id: int)
signal handshake_fail(reason: String)
signal data_received(peer_id: int, channel: int, reliable: bool, payload: Variant)
signal lobby_created(lobby_id: String, members: Array, passcode: String)
signal lobby_joined(lobby_id: String, members: Array)
signal lobby_left(lobby_id: String)
signal lobby_list_received(lobbies: Array)
signal lobby_member_joined(lobby_id: String, peer_id: int, username: String)
signal lobby_member_left(lobby_id: String, peer_id: int)
signal lobby_error(reason: String)

var _ws: WebSocketPeer
var _peer_id: int = -1
var _handshaken: bool = false
var _pending_username: String = ""
var _pending_url: String = ""
var _handshake_elapsed: float = -1.0
var _unreliable_rate_window_start_ms: int = 0
var _unreliable_count: int = 0
## Pending PackedByteArray segments per (target, channel, reliable); flushed after poll / flush_pending_sends.
var _out_queues: Dictionary = {}


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


func poll() -> void:
	if _ws == null:
		return
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		_ws.poll()
		if not _handshaken and _handshake_elapsed < 0.0 and not _pending_url.is_empty():
			_log("WebSocket opened, sending handshake")
			_send_handshake()
		var code := _ws.get_close_code()
		while _ws.get_available_packet_count() > 0:
			var packet := _ws.get_packet()
			if packet.size() >= CONTROL_HEADER_SIZE and packet.decode_u32(0) == CONTROL_MAGIC_U32_LE:
				_handle_control_binary_packet(packet)
				continue
			if packet.size() >= RELAY_V2_HEADER_SIZE:
				var rm := packet.decode_u32(0)
				if rm == RELAY_V2_MAGIC_U32_LE or rm == RELAY_MAGIC_U32_LE:
					_handle_relay_binary_packet(packet)
					continue
			var text := packet.get_string_from_utf8()
			if text.is_empty():
				continue
			_handle_handshake_text(text)
		if code != -1:
			_log("Connection closed by peer, code=%s" % code)
			_close_connection()
			return
		_flush_outgoing_queues()
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
	_unreliable_count = 0
	_unreliable_rate_window_start_ms = 0
	_out_queues.clear()
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
	_unreliable_count = 0
	_unreliable_rate_window_start_ms = 0
	_out_queues.clear()
	set_process(false)
	handshake_fail.emit(reason)
	push_error("[Rakiy] %s" % reason)


func _send_handshake() -> void:
	var msg := {"t": "hs", "v": PROTOCOL_VERSION, "u": _pending_username}
	var body := JSON.stringify(msg)
	_log("Sending handshake: %s" % body)
	var err := _ws.send_text(body)
	if err != OK:
		_log("send_text failed during handshake: %s" % error_string(err))
	_handshake_elapsed = 0.0
	websocket_opened.emit()


func _handle_handshake_text(text: String) -> void:
	_log("Received: %s" % text.substr(0, 200) + ("..." if text.length() > 200 else ""))
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		_log("JSON parse error: %s" % error_string(err))
		return
	var data: Variant = json.get_data()
	if data == null or typeof(data) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = data
	var t: String = str(msg.get("t", ""))
	if t == "ok":
		_handshaken = true
		_handshake_elapsed = -1.0
		_peer_id = int(msg.get("p", -1))
		_log("Handshake OK, peer_id=%d" % _peer_id)
		handshake_ok.emit(_peer_id)
	elif t == "fail":
		var reason: String = str(msg.get("r", "Unknown"))
		_log("Handshake FAIL: %s" % reason)
		push_error("[Rakiy] Handshake failed: %s" % reason)
		handshake_fail.emit(reason)


func _read_utf16_len_string(packet: PackedByteArray, offset: int) -> Dictionary:
	## Returns { "s": String, "next": int } or empty on error
	if offset + 2 > packet.size():
		return {}
	var slen: int = packet.decode_u16(offset)
	var start := offset + 2
	if start + slen > packet.size():
		return {}
	var slice := packet.slice(start, start + slen)
	return {"s": slice.get_string_from_utf8(), "next": start + slen}


func _handle_control_binary_packet(packet: PackedByteArray) -> void:
	if packet.size() < CONTROL_HEADER_SIZE:
		return
	if packet.decode_u32(0) != CONTROL_MAGIC_U32_LE:
		return
	var op: int = packet[4]
	var o := 5
	match op:
		OP_SRV_CREATED, OP_SRV_JOINED:
			var lid := _read_utf16_len_string(packet, o)
			if lid.is_empty():
				return
			o = int(lid.next)
			var lobby_id: String = lid.s
			if o >= packet.size():
				return
			var nmem: int = int(packet[o])
			o += 1
			var members: Array = []
			for _i in range(nmem):
				if o + 5 > packet.size():
					return
				var pid: int = int(packet.decode_u32(o))
				o += 4
				var ulen: int = int(packet[o])
				o += 1
				if o + ulen > packet.size():
					return
				var uname := packet.slice(o, o + ulen).get_string_from_utf8()
				o += ulen
				members.append({"peer_id": pid, "username": uname})
			var passcode := ""
			if op == OP_SRV_CREATED and o < packet.size():
				var plen: int = int(packet[o])
				o += 1
				if plen > 0 and o + plen <= packet.size():
					passcode = packet.slice(o, o + plen).get_string_from_utf8()
			if op == OP_SRV_CREATED:
				lobby_created.emit(lobby_id, members, passcode)
			else:
				lobby_joined.emit(lobby_id, members)
		OP_SRV_LEFT:
			var l2 := _read_utf16_len_string(packet, o)
			if l2.is_empty():
				return
			lobby_left.emit(l2.s)
		OP_SRV_LIST:
			if o + 2 > packet.size():
				return
			var nentries: int = int(packet.decode_u16(o))
			o += 2
			var lobbies: Array = []
			for _j in range(nentries):
				if o + 6 > packet.size():
					return
				var idlen: int = int(packet.decode_u16(o))
				o += 2
				var mc: int = int(packet[o])
				o += 1
				var maxp_b: int = int(packet[o])
				o += 1
				var namelen: int = int(packet.decode_u16(o))
				o += 2
				if o + idlen + namelen > packet.size():
					return
				var lid_str := packet.slice(o, o + idlen).get_string_from_utf8()
				o += idlen
				var nm_str := packet.slice(o, o + namelen).get_string_from_utf8()
				o += namelen
				var entry := {
					"lobby_id": lid_str,
					"member_count": mc,
				}
				if maxp_b != 0xFF:
					entry["max_players"] = maxp_b
				if namelen > 0:
					entry["name"] = nm_str
				lobbies.append(entry)
			lobby_list_received.emit(lobbies)
		OP_SRV_MEMBER_JOIN:
			var l3 := _read_utf16_len_string(packet, o)
			if l3.is_empty():
				return
			o = int(l3.next)
			if o + 4 > packet.size():
				return
			var join_pid: int = int(packet.decode_u32(o))
			o += 4
			var uln: int = int(packet[o])
			o += 1
			if o + uln > packet.size():
				return
			var join_u := packet.slice(o, o + uln).get_string_from_utf8()
			lobby_member_joined.emit(l3.s, join_pid, join_u)
		OP_SRV_MEMBER_LEAVE:
			var l4 := _read_utf16_len_string(packet, o)
			if l4.is_empty():
				return
			o = int(l4.next)
			if o + 4 > packet.size():
				return
			var leave_pid: int = int(packet.decode_u32(o))
			lobby_member_left.emit(l4.s, leave_pid)
		OP_SRV_ERROR:
			var er := _read_utf16_len_string(packet, o)
			if er.is_empty():
				return
			lobby_error.emit(er.s)


func _handle_relay_binary_packet(packet: PackedByteArray) -> void:
	var magic: int = int(packet.decode_u32(0))
	var from_id: int
	var channel: int
	var flags: int
	var payload_len: int
	var header_sz: int
	if magic == RELAY_V2_MAGIC_U32_LE:
		if packet.size() < RELAY_V2_HEADER_SIZE:
			return
		from_id = int(packet.decode_u32(4))
		channel = int(packet.decode_u16(8))
		flags = int(packet[10])
		payload_len = int(packet.decode_u16(12))
		if payload_len > RELAY_V2_MAX_PAYLOAD:
			return
		header_sz = RELAY_V2_HEADER_SIZE
	elif magic == RELAY_MAGIC_U32_LE:
		if packet.size() < RELAY_HEADER_SIZE:
			return
		from_id = int(packet.decode_u32(4))
		channel = int(packet.decode_u16(8))
		flags = int(packet[10])
		payload_len = int(packet.decode_u32(12))
		if payload_len > RELAY_MAX_PAYLOAD:
			_log("relay binary: payload_length over max, dropping")
			return
		header_sz = RELAY_HEADER_SIZE
	else:
		return
	if packet.size() != header_sz + payload_len:
		_log("relay binary: frame size mismatch (got %d, expected %d)" % [packet.size(), header_sz + payload_len])
		return
	var reliable: bool = (flags & RELAY_FLAG_RELIABLE) != 0
	var body := packet.slice(header_sz, header_sz + payload_len)
	if (flags & RELAY_FLAG_UTF8_PAYLOAD) != 0:
		data_received.emit(from_id, channel, reliable, body.get_string_from_utf8())
	elif body.size() >= 2 and body[0] == RakiyPack.FORMAT_MERGED_SEGMENTS:
		for seg in RakiyPack.unpack_merged_segments(body):
			if seg is PackedByteArray:
				data_received.emit(from_id, channel, reliable, seg as PackedByteArray)
	else:
		data_received.emit(from_id, channel, reliable, body)


func _append_utf16_len_string(buf: PackedByteArray, s: String) -> void:
	## u16 length prefix is little-endian (matches server control-binary and decode_u16).
	var b := s.to_utf8_buffer()
	var slen: int = b.size()
	buf.append(slen & 0xFF)
	buf.append((slen >> 8) & 0xFF)
	for i in range(slen):
		buf.append(b[i])


func _pack_relay_outbound(target_peer_id: int, channel: int, reliable: bool, payload: Variant) -> PackedByteArray:
	var body: PackedByteArray
	var flags: int = 0
	if reliable:
		flags |= RELAY_FLAG_RELIABLE
	if payload is String:
		body = (payload as String).to_utf8_buffer()
		flags |= RELAY_FLAG_UTF8_PAYLOAD
	elif payload is PackedByteArray:
		body = payload as PackedByteArray
	else:
		body = str(payload).to_utf8_buffer()
		flags |= RELAY_FLAG_UTF8_PAYLOAD
	if body.size() > RELAY_MAX_PAYLOAD:
		if debug:
			_log("send_data: payload exceeds RELAY_MAX_PAYLOAD (%d)" % RELAY_MAX_PAYLOAD)
		return PackedByteArray()
	if body.size() <= RELAY_V2_MAX_PAYLOAD:
		var frame := PackedByteArray()
		frame.resize(RELAY_V2_HEADER_SIZE)
		frame.encode_u32(0, RELAY_V2_MAGIC_U32_LE)
		frame.encode_u32(4, target_peer_id & 0xFFFFFFFF)
		frame.encode_u16(8, channel & 0xFFFF)
		frame[10] = flags & 0xFF
		frame[11] = 0
		frame.encode_u16(12, body.size() & 0xFFFF)
		frame.append_array(body)
		return frame
	var frame_v1 := PackedByteArray()
	frame_v1.resize(RELAY_HEADER_SIZE)
	frame_v1.encode_u32(0, RELAY_MAGIC_U32_LE)
	frame_v1.encode_u32(4, target_peer_id & 0xFFFFFFFF)
	frame_v1.encode_u16(8, channel & 0xFFFF)
	frame_v1[10] = flags & 0xFF
	frame_v1[11] = 0
	frame_v1.encode_u32(12, body.size())
	frame_v1.append_array(body)
	return frame_v1


func _pack_control_packet(op: int, payload_after_op: PackedByteArray) -> PackedByteArray:
	var p := PackedByteArray()
	p.resize(CONTROL_HEADER_SIZE + payload_after_op.size())
	p.encode_u32(0, CONTROL_MAGIC_U32_LE)
	p[4] = op & 0xFF
	for i in range(payload_after_op.size()):
		p[CONTROL_HEADER_SIZE + i] = payload_after_op[i]
	return p


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
	poll()


func disconnect_from_host() -> void:
	if _ws != null:
		_ws.close()
	_peer_id = -1
	_handshaken = false
	_pending_url = ""
	_pending_username = ""
	_handshake_elapsed = -1.0
	_out_queues.clear()
	set_process(false)


func is_connected_to_host() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


func is_connecting() -> bool:
	return not _pending_url.is_empty() and not _handshaken


func is_handshaken() -> bool:
	return _handshaken


func get_peer_id() -> int:
	return _peer_id


func _queue_key(target_peer_id: int, channel: int, reliable: bool) -> String:
	return "%d|%d|%d" % [target_peer_id, channel, 1 if reliable else 0]


func _flush_outgoing_queues() -> void:
	if _out_queues.is_empty():
		return
	var keys: Array = _out_queues.keys()
	for k in keys:
		_flush_binary_queue_key(str(k))


func _flush_binary_queue_key(key: String) -> void:
	if not _out_queues.has(key):
		return
	var segs: Array = _out_queues[key]
	_out_queues.erase(key)
	var parts := key.split("|")
	if parts.size() != 3:
		return
	var target_peer_id := int(parts[0])
	var channel := int(parts[1])
	var reliable := int(parts[2]) == 1
	while segs.size() > 0:
		if not _rate_limit_allows_unreliable(channel, reliable):
			break
		var body := _pop_next_outbound_blob(segs)
		if body.is_empty():
			break
		_send_relay_immediate_after_rate_check(target_peer_id, channel, reliable, body)
	if segs.size() > 0:
		_out_queues[key] = segs


func _pop_next_outbound_blob(segs: Array) -> PackedByteArray:
	if segs.is_empty():
		return PackedByteArray()
	if segs.size() == 1:
		return segs.pop_front() as PackedByteArray
	var merged: PackedByteArray = RakiyPack.pack_merged_segments(segs.duplicate())
	if merged.size() <= RELAY_V2_MAX_PAYLOAD:
		segs.clear()
		return merged
	return segs.pop_front() as PackedByteArray


func _rate_limit_allows_unreliable(channel: int, reliable: bool) -> bool:
	if unreliable_send_rate_cap <= 0 or reliable or channel != CHANNEL_UNRELIABLE_GAME:
		return true
	var now_ms: int = Time.get_ticks_msec()
	var window_ms: int = maxi(1, int(unreliable_send_rate_window_sec * 1000.0))
	if now_ms - _unreliable_rate_window_start_ms >= window_ms:
		_unreliable_rate_window_start_ms = now_ms
		_unreliable_count = 0
	return _unreliable_count < unreliable_send_rate_cap


func _send_relay_immediate_after_rate_check(target_peer_id: int, channel: int, reliable: bool, payload: Variant) -> void:
	if not _handshaken or _ws == null or not is_connected_to_host():
		return
	if unreliable_send_rate_cap > 0 and not reliable and channel == CHANNEL_UNRELIABLE_GAME:
		_unreliable_count += 1
	var frame := _pack_relay_outbound(target_peer_id, channel, reliable, payload)
	if frame.is_empty():
		return
	var err := _ws.put_packet(frame)
	if err != OK:
		_log("send_data failed: %s" % error_string(err))


func _send_relay_immediate(target_peer_id: int, channel: int, reliable: bool, payload: Variant) -> void:
	if not _handshaken or _ws == null or not is_connected_to_host():
		return
	if not _rate_limit_allows_unreliable(channel, reliable):
		return
	_send_relay_immediate_after_rate_check(target_peer_id, channel, reliable, payload)


## Flush queued binary `PackedByteArray` sends (merged per target/channel/reliable). Call after `poll()` if you drive the client manually without `_process`.
func flush_pending_sends() -> void:
	_flush_outgoing_queues()


func send_data(target_peer_id: int, channel: int, reliable: bool, payload: Variant) -> void:
	if not _handshaken or _ws == null or not is_connected_to_host():
		return
	var key := _queue_key(target_peer_id, channel, reliable)
	if payload is PackedByteArray:
		var pb: PackedByteArray = payload as PackedByteArray
		if pb.is_empty():
			return
		var arr: Array = _out_queues.get(key, [])
		arr.append(pb)
		_out_queues[key] = arr
		return
	_flush_binary_queue_key(key)
	_send_relay_immediate(target_peer_id, channel, reliable, payload)


func send_lobby_broadcast(channel: int, reliable: bool, payload: Variant) -> void:
	send_data(RakiyConstants.TARGET_LOBBY_BROADCAST, channel, reliable, payload)


func lobby_create(name_: String = "", max_players: int = 4, metadata: Dictionary = {}, game_id: String = "", private_lobby: bool = false) -> void:
	if not _handshaken or _ws == null:
		return
	var meta_str := JSON.stringify(metadata)
	var payload := PackedByteArray()
	payload.append(max_players & 0xFF)
	_append_utf16_len_string(payload, game_id)
	_append_utf16_len_string(payload, name_)
	_append_utf16_len_string(payload, meta_str)
	if private_lobby:
		payload.append(CREATE_FLAG_PRIVATE)
	var pkt := _pack_control_packet(OP_CLIENT_CREATE, payload)
	var err := _ws.put_packet(pkt)
	if err != OK:
		_log("lobby_create send failed: %s" % error_string(err))


func lobby_join(lobby_id: String, game_id: String, passcode: String = "") -> void:
	if not _handshaken or _ws == null:
		return
	var payload := PackedByteArray()
	_append_utf16_len_string(payload, lobby_id)
	_append_utf16_len_string(payload, game_id)
	if not passcode.is_empty():
		_append_utf16_len_string(payload, passcode)
	var pkt := _pack_control_packet(OP_CLIENT_JOIN, payload)
	var err := _ws.put_packet(pkt)
	if err != OK:
		_log("lobby_join send failed: %s" % error_string(err))


func lobby_leave(lobby_id: String) -> void:
	if not _handshaken or _ws == null:
		return
	var payload := PackedByteArray()
	_append_utf16_len_string(payload, lobby_id)
	var pkt := _pack_control_packet(OP_CLIENT_LEAVE, payload)
	var err := _ws.put_packet(pkt)
	if err != OK:
		_log("lobby_leave send failed: %s" % error_string(err))


func lobby_list(game_id: String = "", subscribe: bool = false) -> void:
	if not _handshaken or _ws == null:
		return
	var flags := 0
	if subscribe:
		flags |= 1
	if not game_id.is_empty():
		flags |= 2
	var payload := PackedByteArray()
	payload.append(flags & 0xFF)
	if not game_id.is_empty():
		_append_utf16_len_string(payload, game_id)
	var pkt := _pack_control_packet(OP_CLIENT_LIST, payload)
	var err := _ws.put_packet(pkt)
	if err != OK:
		_log("lobby_list send failed: %s" % error_string(err))
