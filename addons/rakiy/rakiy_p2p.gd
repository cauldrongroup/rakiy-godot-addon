class_name RakiyP2P
extends RefCounted

## Native WebRTC: offerer creates a data channel; answerer receives it via [signal WebRTCPeerConnection.data_channel_received].
## Signaling uses [member RakiyConstants.CHANNEL_SIGNALING] on the Rakiy relay (JSON text).

signal p2p_peer_connected(peer_id: int)
signal p2p_peer_disconnected(peer_id: int)

var stun_servers: PackedStringArray = PackedStringArray(["stun:stun.l.google.com:19302"])
var turn_servers: PackedStringArray = PackedStringArray()
var turn_username: String = ""
var turn_password: String = ""

var _client: Node = null
var _local_id: int = -1
## peer_id -> state Dictionary
var _by_peer: Dictionary = {}

func attach_client(c: Node) -> void:
	if _client and _client != c:
		cleanup()
	_client = c
	if c == null:
		return
	c.lobby_created.connect(func(_lid: String, members: Array, _pc: String): _sync_members(members))
	c.lobby_joined.connect(func(_lid: String, members: Array): _sync_members(members))
	c.lobby_member_joined.connect(_on_member_join)
	c.lobby_member_left.connect(_on_member_left)
	c.disconnected.connect(cleanup)

func on_handshake_ok(peer_id: int) -> void:
	_local_id = peer_id
	if not _webrtc_available() and _client != null and _client.get("handshake_capability") == "p2p":
		push_warning(
			"RakiyP2P: WebRTCPeerConnection is missing from this Godot build; "
			+ "signaling may run but data channels will not open — use a build with the WebRTC module."
		)

func cleanup() -> void:
	for pid in _by_peer.keys():
		_close_peer(int(pid))
	_by_peer.clear()
	_local_id = -1
	_client = null

func poll() -> void:
	if not _webrtc_available():
		return
	for pid in _by_peer.keys():
		var st: Dictionary = _by_peer[pid]
		var pc: WebRTCPeerConnection = st.pc
		if pc:
			pc.poll()
		var dc: WebRTCDataChannel = st.get("dc", null)
		if dc and dc.get_ready_state() == WebRTCDataChannel.STATE_OPEN and not st.get("hi", false):
			st.hi = true
			_by_peer[pid] = st
			p2p_peer_connected.emit(int(pid))

func on_signaling_incoming(from_peer_id: int, payload: PackedByteArray, _is_utf8: bool) -> void:
	if not _webrtc_available() or _client == null:
		return
	# Always decode as UTF-8: some proxies strip RELAY_FLAG_UTF8 even for JSON signaling.
	var txt := payload.get_string_from_utf8()
	if txt.is_empty():
		if _client.has_method("log_p2p"):
			_client.log_p2p("signaling empty payload from peer %d" % from_peer_id)
		return
	var j = JSON.new()
	if j.parse(txt) != OK:
		if _client.has_method("log_p2p"):
			_client.log_p2p("signaling JSON parse fail from peer %d: %s…" % [from_peer_id, txt.substr(0, 64)])
		return
	var d = j.data
	if typeof(d) != TYPE_DICTIONARY:
		return
	var kind: String = str(d.get("t", ""))
	if _client.has_method("log_p2p") and (kind == "offer" or kind == "answer" or kind == "candidate"):
		_client.log_p2p("sig in %s from peer %d" % [kind, from_peer_id])
	if kind == "offer":
		_handle_offer(from_peer_id, str(d.get("sdp", "")))
	elif kind == "answer":
		_handle_answer(from_peer_id, str(d.get("sdp", "")))
	elif kind == "candidate":
		_handle_candidate(
			from_peer_id,
			str(d.get("media", "")),
			int(d.get("i", 0)),
			str(d.get("s", d.get("name", ""))),
		)

func try_send_p2p(target_peer_id: int, channel: int, reliable: bool, payload: Variant) -> bool:
	if not _webrtc_available():
		return false
	if not _by_peer.has(target_peer_id):
		return false
	var st: Dictionary = _by_peer[target_peer_id]
	var dc: WebRTCDataChannel = st.dc
	if dc == null or dc.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
		return false
	var pl: PackedByteArray = (
		str(payload).to_utf8_buffer() if typeof(payload) == TYPE_STRING else payload
	)
	var hdr := PackedByteArray()
	hdr.resize(3)
	hdr.encode_u16(0, channel & 0xFFFF)
	hdr[2] = 1 if reliable else 0
	dc.put_packet(hdr + pl)
	return true

func try_deliver_incoming(_from_peer_id: int, _channel: int, _reliable: bool, _payload: Variant) -> bool:
	return false


func count_open_data_channels() -> int:
	var n := 0
	for pid in _by_peer.keys():
		var st: Dictionary = _by_peer[pid]
		var dc: WebRTCDataChannel = st.get("dc", null)
		if dc != null and dc.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			n += 1
	return n


func _webrtc_available() -> bool:
	return ClassDB.class_exists("WebRTCPeerConnection")

func _ice_servers() -> Array:
	var arr: Array = []
	for s in stun_servers:
		if str(s).strip_edges() != "":
			arr.append({"urls": [str(s)]})
	for s in turn_servers:
		if str(s).strip_edges() != "":
			var o := {"urls": [str(s)]}
			if turn_username != "":
				o["username"] = turn_username
				o["credential"] = turn_password
			arr.append(o)
	if arr.is_empty():
		arr.append({"urls": ["stun:stun.l.google.com:19302"]})
	return arr

func _sync_members(members: Array) -> void:
	if _client == null or _client.handshake_capability != "p2p":
		return
	if _client.has_method("log_p2p"):
		_client.log_p2p("_sync_members n=%d local_id=%d" % [members.size(), _local_id])
	var want := {}
	for m in members:
		if m is not Dictionary:
			continue
		var md: Dictionary = m
		var pid: int = int(md.get("peer_id", -1))
		var cap: int = int(md.get("capability", 0))
		if pid == _local_id:
			continue
		want[pid] = cap
		if cap == RakiyConstants.MEMBER_CAP_P2P and _local_id >= 0:
			_maybe_start_peer(pid)
	for pid in _by_peer.keys():
		if not want.has(int(pid)):
			_close_peer(int(pid))

func _maybe_start_peer(remote_id: int) -> void:
	if _by_peer.has(remote_id):
		return
	if _local_id < 0:
		return
	# Lower peer_id offers so both sides don't glare.
	if _local_id < remote_id:
		_start_as_offerer(remote_id)

func _on_member_join(_lobby_id: String, peer_id: int, _username: String, capability: int) -> void:
	_try_add_from_event(peer_id, capability)

func _try_add_from_event(peer_id: int, capability: int) -> void:
	if capability != RakiyConstants.MEMBER_CAP_P2P or _client == null:
		return
	if _client.handshake_capability != "p2p" or _local_id < 0:
		return
	if peer_id == _local_id:
		return
	_maybe_start_peer(peer_id)

func _on_member_left(_lobby_id: String, peer_id: int) -> void:
	_close_peer(peer_id)

func _start_as_offerer(remote_id: int) -> void:
	if not _webrtc_available():
		return
	var pc := WebRTCPeerConnection.new()
	var ierr := pc.initialize({"iceServers": _ice_servers()})
	if ierr != OK:
		if _client.has_method("log_p2p"):
			_client.log_p2p("WebRTC initialize failed for peer %d: %s" % [remote_id, error_string(ierr)])
		return
	pc.session_description_created.connect(
		func(t: String, sdp: String): _finalize_local_desc(remote_id, t, sdp)
	)
	pc.ice_candidate_created.connect(
		func(media: String, index: int, cand_line: String):
			_send_sig(
				remote_id,
				JSON.stringify(
					{"t": "candidate", "media": media, "i": index, "s": cand_line}
				)
			)
	)
	var dc := pc.create_data_channel("rakiy", {"ordered": true})
	if dc == null:
		if _client.has_method("log_p2p"):
			_client.log_p2p("create_data_channel null for peer %d" % remote_id)
		return
	dc.message_received.connect(func(m: Variant): _on_dc_message(remote_id, m))
	_by_peer[remote_id] = {"pc": pc, "dc": dc}
	var oerr := pc.create_offer()
	if oerr != OK:
		if _client.has_method("log_p2p"):
			_client.log_p2p("create_offer failed for peer %d: %s" % [remote_id, error_string(oerr)])
		_close_peer(remote_id)
		return
	if _client.has_method("log_p2p"):
		_client.log_p2p("create_offer OK, waiting session_description (peer %d)" % remote_id)

func _finalize_local_desc(remote_id: int, type_str: String, sdp: String) -> void:
	var st: Dictionary = _by_peer.get(remote_id, {})
	var pc: WebRTCPeerConnection = st.get("pc", null)
	if pc == null:
		return
	pc.set_local_description(type_str, sdp)
	_send_sig(remote_id, JSON.stringify({"t": type_str.to_lower(), "sdp": sdp}))

func _handle_offer(from_peer_id: int, sdp: String) -> void:
	if not _webrtc_available():
		return
	if _by_peer.has(from_peer_id):
		return
	var pc := WebRTCPeerConnection.new()
	var ierr := pc.initialize({"iceServers": _ice_servers()})
	if ierr != OK:
		if _client.has_method("log_p2p"):
			_client.log_p2p("answerer initialize failed peer %d: %s" % [from_peer_id, error_string(ierr)])
		return
	pc.session_description_created.connect(
		func(t: String, ans: String): _finalize_local_desc(from_peer_id, t, ans)
	)
	pc.ice_candidate_created.connect(
		func(media: String, index: int, cand_line: String):
			_send_sig(
				from_peer_id,
				JSON.stringify(
					{"t": "candidate", "media": media, "i": index, "s": cand_line}
				)
			)
	)
	pc.data_channel_received.connect(func(ch: WebRTCDataChannel): _bind_remote_dc(from_peer_id, ch))
	_by_peer[from_peer_id] = {"pc": pc, "dc": null}
	if pc.set_remote_description("offer", sdp) != OK:
		_close_peer(from_peer_id)
		return
	if pc.create_answer() != OK:
		_close_peer(from_peer_id)

func _bind_remote_dc(remote_id: int, ch: WebRTCDataChannel) -> void:
	if not _by_peer.has(remote_id):
		return
	var st: Dictionary = _by_peer[remote_id]
	st.dc = ch
	ch.message_received.connect(func(m: Variant): _on_dc_message(remote_id, m))
	_by_peer[remote_id] = st

func _handle_answer(from_peer_id: int, sdp: String) -> void:
	var st: Dictionary = _by_peer.get(from_peer_id, {})
	var pc: WebRTCPeerConnection = st.get("pc", null)
	if pc == null:
		return
	pc.set_remote_description("answer", sdp)

func _handle_candidate(from_peer_id: int, media: String, index: int, cand_line: String) -> void:
	var st: Dictionary = _by_peer.get(from_peer_id, {})
	var pc: WebRTCPeerConnection = st.get("pc", null)
	if pc == null:
		return
	pc.add_ice_candidate(media, index, cand_line)

func _on_dc_message(remote_id: int, message: Variant) -> void:
	var raw: PackedByteArray
	if typeof(message) == TYPE_STRING:
		raw = str(message).to_utf8_buffer()
	else:
		raw = message
	if raw.size() < 3:
		return
	var ch := raw.decode_u16(0)
	var rel := raw[2] != 0
	var body := raw.slice(3)
	if _client:
		_client.record_p2p_game_inbound()
		_client.data_received.emit(remote_id, ch, rel, body)

func _send_sig(remote_id: int, json_txt: String) -> void:
	if _client:
		if _client.has_method("log_p2p"):
			_client.log_p2p("sig out → peer %d (%d bytes)" % [remote_id, json_txt.length()])
		_client.send_data(remote_id, RakiyConstants.CHANNEL_SIGNALING, true, json_txt)

func _close_peer(remote_id: int) -> void:
	if not _by_peer.has(remote_id):
		return
	var st: Dictionary = _by_peer[remote_id]
	var pc: WebRTCPeerConnection = st.get("pc", null)
	if pc:
		pc.close()
	_by_peer.erase(remote_id)
	p2p_peer_disconnected.emit(remote_id)
