class_name SessionClient
extends Node

enum State {
	DISCONNECTED,
	CONNECTING,
	ORPHAN,
	PENDING_JOIN,
	OPEN_SESSION,
	SEALED_SESSION,
	PENDING_READY,
	CLOSING
}
	

var _ws: WebSocketPeer = WebSocketPeer.new()
var _state: State = State.DISCONNECTED
# The session code, if we are connected to a session.
# Reset to empty string on `_cleanup()`. Thus, if `_state` is DISCONNECTED but `_session_code` is not empty, we must haev a ready session.
var _session_code: String = ""

signal _on_disconnected
signal _on_connecting
signal _on_orphan
signal _on_pending_join
signal _on_open_session
signal _on_sealed_session
signal _on_pending_ready
signal _on_closing

func connect_to_url(url: String) -> bool:
	# Await on `leave()` to guarantee a DISCONNECTED start.
	await leave()
	if _state != State.DISCONNECTED:
		printerr("Error: SessionClient is in non-DISCONNECTED state after `leave()`.")
		printerr("Error: Code shouldn't reach here.")
		return false
	
	if _ws.connect_to_url(url):
		printerr("Error: Failed to connect to url.")
		return false
	
	_state = State.CONNECTING
	_on_connecting.emit()
	# Now wait for the connection to succeed, or fail.
	await Join.new([_on_disconnected, _on_orphan]).any()
	if _state == State.DISCONNECTED:
		return false
	return true
	
func host() -> String:
	if _state != State.ORPHAN:
		printerr("Error: SessionClient is in non-ORPHAN state when `host()` was called.")
		return ""
	# Send a JOIN message to the server.
	var host = Message.new(Message.Type.JOIN, 0, 0, "").as_json().to_utf8_buffer()
	_ws.put_packet(host)
	
	_state = State.PENDING_JOIN
	_on_pending_join.emit()
	# Now wait for JOIN to succeed, or fail.
	await Join.new([_on_orphan, _on_open_session]).any()
	if _state == State.ORPHAN:
		return ""
	return _session_code
	
func join(session_code: String) -> bool:
	if _state != State.ORPHAN:
		printerr("Error: SessionClient is in non-ORPHAN state when `join()` was called.")
		return false
	# Send a JOIN message to the server.
	var join = Message.new(Message.Type.JOIN, 0, 0, session_code).as_json().to_utf8_buffer()
	_ws.put_packet(join)
	
	_state = State.PENDING_JOIN
	_on_pending_join.emit()
	# Now wait for JOIN to succeed, or fail.
	await Join.new([_on_orphan, _on_open_session]).any()
	if _state == State.ORPHAN:
		return false
	return true
	
func seal() -> bool:
	if _state != State.OPEN_SESSION:
		printerr("Error: SessionClient is in non-OPEN_SESSION state when `seal()` was called.")
		return false
	# If we don't have a multiplayer peer, something must've gone wrong.
	if !multiplayer.has_multiplayer_peer():
		printerr("Error: SessionClient called `seal()`, but doesn't have a multiplayer peer.")
		return false
	var multiplayer_peer = multiplayer.multiplayer_peer
	# If we are not the host, abort.
	if multiplayer_peer.get_unique_id() != 1:
		printerr("Error: SessionClient is not the host, but called `seal()`.")
		return false
	
	# Send a SEAL message to the server.
	var seal = Message.new(Message.Type.SEAL, multiplayer_peer.get_unique_id(), 0, null).as_json().to_utf8_buffer()
	_ws.put_packet(seal)
	
	# Now wait for _on_sealed_session.
	await _on_sealed_session
	if _state == State.SEALED_SESSION:
		return true
	printerr("Error: Code shouldn't reach here.")
	return false
	
func wait_until_ready() -> bool:
	while _state != State.DISCONNECTED:
		await _on_disconnected
	# If `_session_code` is a non-empty string, we must've followed the intended path (PENDING_READY -> CLOSING -> DISCONNECTED).
	if _session_code != "":
		return true
	# Else, we either didn't try connecting yet, or failed to connect.
	return false
	
func leave() -> void:
	# Close the websocket, cleanup all multiplayers, and transition into CLOSING.
	_ws.close(1000, "Client requested to leave.")
	_cleanup()
	_state = State.CLOSING
	_on_closing.emit()
	# Then wait until everything is reset to DISCONNECTED.
	while _state != State.DISCONNECTED:
		await _on_disconnected
	return

func _process(delta):
	var new_state: State = _state
	match _state:
		State.DISCONNECTED:
			new_state = _process_disconnected()
		State.CONNECTING:
			new_state = _process_connecting()
		State.ORPHAN:
			new_state = _process_orphan()
		State.PENDING_JOIN:
			new_state = _process_pending_join()
		State.OPEN_SESSION:
			new_state = _process_open_session()
		State.SEALED_SESSION:
			new_state = _process_sealed_session()
		State.PENDING_READY:
			new_state = _process_pending_ready()
		State.CLOSING:
			new_state = _process_closing()
	if _state != new_state:
		_state = new_state
		match _state:
			State.DISCONNECTED:
				_on_disconnected.emit()
			State.CONNECTING:
				_on_connecting.emit()
			State.ORPHAN:
				_on_orphan.emit()
			State.PENDING_JOIN:
				_on_pending_join.emit()
			State.OPEN_SESSION:
				_on_open_session.emit()
			State.SEALED_SESSION:
				_on_sealed_session.emit()
			State.PENDING_READY:
				_on_pending_ready.emit()
			State.CLOSING:
				_on_closing.emit()
	

func _process_disconnected() -> State:
	# DISCONNECTED won't transition to another state, unless `connect_to_url()` is called.
	# `poll()` shouldn't be necessary, but I'll leave it here just in case.
	_ws.poll()
	if _ws.get_ready_state() != WebSocketPeer.State.STATE_CLOSED:
		printerr("Error: SessionClient is in state DISCONNECTED, but has a non-STATE_CLOSED websocket.")
	return State.DISCONNECTED

func _process_connecting() -> State:
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.State.STATE_CLOSED:
			return State.DISCONNECTED
		WebSocketPeer.State.STATE_CLOSING:
			return State.CLOSING
		WebSocketPeer.State.STATE_CONNECTING:
			return State.CONNECTING
		WebSocketPeer.State.STATE_OPEN:
			return State.ORPHAN
	printerr("Error: Code shouldn't reach here.")
	return State.CONNECTING

func _process_orphan() -> State:
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.State.STATE_CLOSING:
			_cleanup()
			return State.CLOSING
		WebSocketPeer.State.STATE_CLOSED:
			_cleanup()
			return State.DISCONNECTED
		WebSocketPeer.State.STATE_CONNECTING:
			printerr("Error: SessionClient is in state ORPHAN, but has a STATE_CONNECTING websocket.")
			_cleanup()
			return State.CONNECTING
		WebSocketPeer.State.STATE_OPEN:
			return State.ORPHAN
	printerr("Error: Code shouldn't reach here.")
	return State.ORPHAN

func _process_pending_join() -> State:
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.State.STATE_CLOSING:
			_cleanup()
			return State.CLOSING
		WebSocketPeer.State.STATE_CLOSED:
			_cleanup()
			return State.DISCONNECTED
		WebSocketPeer.State.STATE_CONNECTING:
			printerr("Error: SessionClient is in state PENDING_JOIN, but has a STATE_CONNECTING websocket.")
			_cleanup()
			return State.CONNECTING
		WebSocketPeer.State.STATE_OPEN:
			pass
	while _ws.get_available_packet_count() != 0:
		var message = Message.from_json(_ws.get_packet().get_string_from_utf8())
		# If received message wasn't properly formatted, send back an ERROR.
		if !message:
			printerr("Error: Received a malformed message during PENDING_JOIN. Expecting properly formatted messages.")
			var reply = Message.new(Message.Type.ERROR, 0, 0, "Expecting properly formatted messages.").as_json().to_utf8_buffer()
			_ws.put_packet(reply)
			continue
		# If received message is a ERROR, printerr.
		if message.type == Message.Type.ERROR:
			printerr("Error: Received a ERROR message from peer {peer_id} during PENDING_JOIN. Error body was: {body}".format({ "peer_id": message.src_peer, "body": message.body }))
			continue
		# If received message isn't a JOIN, send back an ERROR.
		if message.type != Message.Type.JOIN:
			printerr("Error: Received a non-JOIN message during PENDING_JOIN. Expecting JOIN messages.")
			var reply = Message.new(Message.Type.ERROR, 0, 0, "Expecting JOIN messages.").as_json().to_utf8_buffer()
			_ws.put_packet(reply)
			continue
		# If received message isn't coming from the server (src_peer = 0), send back an ERROR.
		if message.src_peer != 0:
			printerr("Error: Received a JOIN message with src_peer {src_peer} during PENDING_JOIN. Expecting non-RELAY messages to come from the server.".format({ "src_peer": message.src_peer }))
			var reply = Message.new(Message.Type.ERROR, 0, 0, "Expecting non-RELAY messages to come from the server.").as_json().to_utf8_buffer()
			_ws.put_packet(reply)
			continue
		# If received JOIN body is an empty string, this JOIN reply denotes a failure.
		if message.body == "":
			return State.ORPHAN
		# Else, we have received a valid JOIN!
		var peer: WebRTCMultiplayerPeer = WebRTCMultiplayerPeer.new()
		# Initialize the multiplayer peer as a mesh.
		# If failed, close the websocket and cleanup everything.
		if peer.create_mesh(message.src_peer):
			printerr("Error: Failed to create a mesh WebRTCMultiplayerPeer.")
			_ws.close(1000, "Client failed to create mesh WebRTCMultiplayerPeer.")
			_cleanup()
			return State.CLOSING
		# Now we have a (empty) multiplayer peer setted up!
		multiplayer.multiplayer_peer = peer
		_session_code = message.body
		return State.OPEN_SESSION
	# We didn't receive a valid JOIN. :(
	return State.PENDING_JOIN

func _process_open_session() -> State:
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.State.STATE_CLOSING:
			_cleanup()
			return State.CLOSING
		WebSocketPeer.State.STATE_CLOSED:
			_cleanup()
			return State.DISCONNECTED
		WebSocketPeer.State.STATE_CONNECTING:
			printerr("Error: SessionClient is in state OPEN_SESSION, but has a STATE_CONNECTING websocket.")
			_cleanup()
			return State.CONNECTING
		WebSocketPeer.State.STATE_OPEN:
			pass
	while _ws.get_available_packet_count() != 0:
		var message = Message.from_json(_ws.get_packet().get_string_from_utf8())
		# If received message wasn't properly formatted, send back an ERROR.
		if !message:
			printerr("Error: Received a malformed message during OPEN_SESSION. Expecting properly formatted messages.")
			var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting properly formatted messages.").as_json().to_utf8_buffer()
			_ws.put_packet(reply)
			continue
		# If received message is a ERROR, printerr.
		if message.type == Message.Type.ERROR:
			printerr("Error: Received a ERROR message from peer {peer_id} during OPEN_SESSION. Error body was: {body}".format({ "peer_id": message.src_peer, "body": message.body }))
			continue
		# If received message isn't PEER_CONNECTED, PEER_DISCONNECTED, RELAY, or SEAL, send back an ERROR.
		if (message.type != Message.Type.PEER_CONNECTED) || (message.type != Message.Type.PEER_DISCONNECTED) || (message.type != Message.Type.RELAY) || (message.type != Message.Type.SEAL):
			printerr("Error: Received a non-PEER_CONNECTED/PEER_DISCONNECTED/RELAY/SEAL message during OPEN_SESSION. Expecting PEER_CONNECTED/PEER_DISCONNECTED/RELAY/SEAL messages.")
			var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting PEER_CONNECTED/PEER_DISCONNECTED/RELAY/SEAL messages.").as_json().to_utf8_buffer()
			_ws.put_packet(reply)
			continue
		# Process PEER_CONNECTEDs.
		if message.type == Message.Type.PEER_CONNECTED:
			# If received message isn't coming from the server (src_peer = 0), send back an ERROR.
			if message.src_peer != 0:
				printerr("Error: Received a PEER_CONNECTED message with src_peer {src_peer} during OPEN_SESSION. Expecting non-RELAY messages to come from the server.".format({ "src_peer": message.src_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting non-RELAY messages to come from the server.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# If received message isn't for me, send back an ERROR.
			if message.dst_peer != multiplayer.get_unique_id():
				printerr("Error: Received a PEER_CONNECTED message with dst_peer {dst_peer} during OPEN_SESSION. Expecting messages destinied to me.".format({ "dst_peer": message.dst_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting messages destinied to me.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# Else, we have received a valid PEER_CONNECTED!
			# Call `handle_peer_connected()` to add new peer to the mesh, and start setting up connections.
			# If `handle_peer_connected()` returned an error, close the websocket and clean up.
			if !_handle_peer_connected(message.body):
				printerr("Error: Client failed to handle PEER_CONNECTED.")
				_ws.close(1000, "Client failed to handle PEER_CONNECTED.")
				_cleanup()
				return State.CLOSING
			continue
		# Process PEER_DISCONNECTEDs.
		if message.type == Message.Type.PEER_DISCONNECTED:
			# If received message isn't coming from the server (src_peer = 0), send back an ERROR.
			if message.src_peer != 0:
				printerr("Error: Received a PEER_DISCONNECTED message with src_peer {src_peer} during OPEN_SESSION. Expecting non-RELAY messages to come from the server.".format({ "src_peer": message.src_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting non-RELAY messages to come from the server.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# If received message isn't for me, send back an ERROR.
			if message.dst_peer != multiplayer.get_unique_id():
				printerr("Error: Received a PEER_DISCONNECTED message with dst_peer {dst_peer} during OPEN_SESSION. Expecting messages destinied to me.".format({ "dst_peer": message.dst_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting messages destinied to me.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# Else, we have received a valid PEER_DISCONNECTED!
			# Call `handle_peer_disconnected()` to remove the peer from the mesh.
			# If `handle_peer_disconnected()` returned an error, close the websocket and clean up.
			if !_handle_peer_disconnected(message.body):
				printerr("Error: Client failed to handle PEER_DISCONNECTED.")
				_ws.close(1000, "Client failed to handle PEER_DISCONNECTED.")
				_cleanup()
				return State.CLOSING
			continue
		# Process RELAYs.
		if message.type == Message.Type.RELAY:
			# If received message isn't coming from a known peer, send back an ERROR.
			if !(message.src_peer in multiplayer.get_peers()):
				printerr("Error: Received a RELAY message with src_peer {src_peer} during OPEN_SESSION. Expecting RELAY messages from existing peers.".format({ "src_peer": message.src_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting RELAY messages from existing peers.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# If received message isn't for me, send back an ERROR.
			if message.dst_peer != multiplayer.get_unique_id():
				printerr("Error: Received a RELAY message with dst_peer {dst_peer} during OPEN_SESSION. Expecting messages destinied to me.".format({ "dst_peer": message.dst_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting messages destinied to me.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# Else, we have received a valid RELAY!
			# Call `handle_relay()` to parse the RELAY body, and help construct the connection.
			# If handle_relay()` returned an error, close the websocket and clean up.
			if !_handle_relay(message.src_peer, message.body):
				printerr("Error: Client failed to handle RELAY.")
				_ws.close(1000, "Client failed to handle RELAY.")
				_cleanup()
				return State.CLOSING
			continue
		# Process SEALs.
		if message.type == Message.Type.SEAL:
			# If received message isn't coming from the server (src_peer = 0), send back an ERROR.
			if message.src_peer != 0:
				printerr("Error: Received a SEAL message with src_peer {src_peer} during OPEN_SESSION. Expecting non-RELAY messages to come from the server.".format({ "src_peer": message.src_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting non-RELAY messages to come from the server.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# If received message isn't for me, send back an ERROR.
			if message.dst_peer != multiplayer.get_unique_id():
				printerr("Error: Received a SEAL message with dst_peer {dst_peer} during OPEN_SESSION. Expecting messages destinied to me.".format({ "dst_peer": message.dst_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting messages destinied to me.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# Else, we have received a valid SEAL!
			# Transition into SEALED_SESSION.
			return State.SEALED_SESSION
	return State.OPEN_SESSION

func _process_sealed_session() -> State:
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.State.STATE_CLOSING:
			_cleanup()
			return State.CLOSING
		WebSocketPeer.State.STATE_CLOSED:
			_cleanup()
			return State.DISCONNECTED
		WebSocketPeer.State.STATE_CONNECTING:
			printerr("Error: SessionClient is in state SEALED_SESSION, but has a STATE_CONNECTING websocket.")
			_cleanup()
			return State.CONNECTING
		WebSocketPeer.State.STATE_OPEN:
			pass
	while _ws.get_available_packet_count() != 0:
		var message = Message.from_json(_ws.get_packet().get_string_from_utf8())
		# If received message wasn't properly formatted, send back an ERROR.
		if !message:
			printerr("Error: Received a malformed message during SEALED_SESSION. Expecting properly formatted messages.")
			var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting properly formatted messages.").as_json().to_utf8_buffer()
			_ws.put_packet(reply)
			continue
		# If received message is a ERROR, printerr.
		if message.type == Message.Type.ERROR:
			printerr("Error: Received a ERROR message from peer {peer_id} during SEALED_SESSION. Error body was: {body}".format({ "peer_id": message.src_peer, "body": message.body }))
			continue
		# If received message isn't PEER_DISCONNECTED, RELAY, send back an ERROR.
		if (message.type != Message.Type.PEER_DISCONNECTED) || (message.type != Message.Type.RELAY):
			printerr("Error: Received a non-PEER_DISCONNECTED/RELAY message during SEALED_SESSION. Expecting PEER_DISCONNECTED/RELAY messages.")
			var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting PEER_DISCONNECTED/RELAY messages.").as_json().to_utf8_buffer()
			_ws.put_packet(reply)
			continue
		# Process PEER_DISCONNECTEDs.
		if message.type == Message.Type.PEER_DISCONNECTED:
			# If received message isn't coming from the server (src_peer = 0), send back an ERROR.
			if message.src_peer != 0:
				printerr("Error: Received a PEER_DISCONNECTED message with src_peer {src_peer} during SEALED_SESSION. Expecting non-RELAY messages to come from the server.".format({ "src_peer": message.src_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting non-RELAY messages to come from the server.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# If received message isn't for me, send back an ERROR.
			if message.dst_peer != multiplayer.get_unique_id():
				printerr("Error: Received a PEER_DISCONNECTED message with dst_peer {dst_peer} during SEALED_SESSION. Expecting messages destinied to me.".format({ "dst_peer": message.dst_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting messages destinied to me.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# Else, we have received a valid PEER_DISCONNECTED!
			# Call `handle_peer_disconnected()` to remove the peer from the mesh.
			# If `handle_peer_disconnected()` returned an error, close the websocket and clean up.
			if !_handle_peer_disconnected(message.body):
				printerr("Error: Client failed to handle PEER_DISCONNECTED.")
				_ws.close(1000, "Client failed to handle PEER_DISCONNECTED.")
				_cleanup()
				return State.CLOSING
			continue
		# Process RELAYs.
		if message.type == Message.Type.RELAY:
			# If received message isn't coming from a known peer, send back an ERROR.
			if !(message.src_peer in multiplayer.get_peers()):
				printerr("Error: Received a RELAY message with src_peer {src_peer} during SEALED_SESSION. Expecting RELAY messages from existing peers.".format({ "src_peer": message.src_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting RELAY messages from existing peers.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# If received message isn't for me, send back an ERROR.
			if message.dst_peer != multiplayer.get_unique_id():
				printerr("Error: Received a RELAY message with dst_peer {dst_peer} during SEALED_SESSION. Expecting messages destinied to me.".format({ "dst_peer": message.dst_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting messages destinied to me.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# Else, we have received a valid RELAY!
			# Call `handle_relay()` to parse the RELAY body, and help construct the connection.
			# If handle_relay()` returned an error, close the websocket and clean up.
			if !_handle_relay(message.src_peer, message.body):
				printerr("Error: Client failed to handle RELAY.")
				_ws.close(1000, "Client failed to handle RELAY.")
				_cleanup()
				return State.CLOSING
			continue
	return State.SEALED_SESSION

func _process_pending_ready() -> State:
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.State.STATE_CLOSING:
			_cleanup()
			return State.CLOSING
		WebSocketPeer.State.STATE_CLOSED:
			_cleanup()
			return State.DISCONNECTED
		WebSocketPeer.State.STATE_CONNECTING:
			printerr("Error: SessionClient is in state PENDING_READY, but has a STATE_CONNECTING websocket.")
			_cleanup()
			return State.CONNECTING
		WebSocketPeer.State.STATE_OPEN:
			pass
	while _ws.get_available_packet_count() != 0:
		var message = Message.from_json(_ws.get_packet().get_string_from_utf8())
		# If received message wasn't properly formatted, send back an ERROR.
		if !message:
			printerr("Error: Received a malformed message during PENDING_READY. Expecting properly formatted messages.")
			var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting properly formatted messages.").as_json().to_utf8_buffer()
			_ws.put_packet(reply)
			continue
		# If received message is a ERROR, printerr.
		if message.type == Message.Type.ERROR:
			printerr("Error: Received a ERROR message from peer {peer_id} during PENDING_READY. Error body was: {body}".format({ "peer_id": message.src_peer, "body": message.body }))
			continue
		# If received message isn't PEER_DISCONNECTED, RELAY, send back an ERROR.
		if (message.type != Message.Type.PEER_DISCONNECTED) || (message.type != Message.Type.RELAY) || (message.type != Message.Type.READY):
			printerr("Error: Received a non-PEER_DISCONNECTED/RELAY/READY message during PENDING_READY. Expecting PEER_DISCONNECTED/RELAY/READY messages.")
			var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting PEER_DISCONNECTED/RELAY/READY messages.").as_json().to_utf8_buffer()
			_ws.put_packet(reply)
			continue
		# Process PEER_DISCONNECTEDs.
		if message.type == Message.Type.PEER_DISCONNECTED:
			# If received message isn't coming from the server (src_peer = 0), send back an ERROR.
			if message.src_peer != 0:
				printerr("Error: Received a PEER_DISCONNECTED message with src_peer {src_peer} during PENDING_READY. Expecting non-RELAY messages to come from the server.".format({ "src_peer": message.src_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting non-RELAY messages to come from the server.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# If received message isn't for me, send back an ERROR.
			if message.dst_peer != multiplayer.get_unique_id():
				printerr("Error: Received a PEER_DISCONNECTED message with dst_peer {dst_peer} during PENDING_READY. Expecting messages destinied to me.".format({ "dst_peer": message.dst_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting messages destinied to me.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# Else, we have received a valid PEER_DISCONNECTED!
			# Call `handle_peer_disconnected()` to remove the peer from the mesh.
			# If `handle_peer_disconnected()` returned an error, close the websocket and clean up.
			if !_handle_peer_disconnected(message.body):
				printerr("Error: Client failed to handle PEER_DISCONNECTED.")
				_ws.close(1000, "Client failed to handle PEER_DISCONNECTED.")
				_cleanup()
				return State.CLOSING
			continue
		# Process RELAYs.
		if message.type == Message.Type.RELAY:
			# If received message isn't coming from a known peer, send back an ERROR.
			if !(message.src_peer in multiplayer.get_peers()):
				printerr("Error: Received a RELAY message with src_peer {src_peer} during PENDING_READY. Expecting RELAY messages from existing peers.".format({ "src_peer": message.src_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting RELAY messages from existing peers.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# If received message isn't for me, send back an ERROR.
			if message.dst_peer != multiplayer.get_unique_id():
				printerr("Error: Received a RELAY message with dst_peer {dst_peer} during PENDING_READY. Expecting messages destinied to me.".format({ "dst_peer": message.dst_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting messages destinied to me.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# Else, we have received a valid RELAY!
			# Call `handle_relay()` to parse the RELAY body, and help construct the connection.
			printerr("Warning: Received a RELAY message during PENDING_READY. Not a big issue...")
			# If handle_relay()` returned an error, close the websocket and clean up.
			if !_handle_relay(message.src_peer, message.body):
				printerr("Error: Client failed to handle RELAY.")
				_ws.close(1000, "Client failed to handle RELAY.")
				_cleanup()
				return State.CLOSING
			continue
		# Process READYs.
		if message.type == Message.Type.READY:
			# If received message isn't coming from the server (src_peer = 0), send back an ERROR.
			if message.src_peer != 0:
				printerr("Error: Received a READY message with src_peer {src_peer} during PENDING_READY. Expecting non-RELAY messages to come from the server.".format({ "src_peer": message.src_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting non-RELAY messages to come from the server.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# If received message isn't for me, send back an ERROR.
			if message.dst_peer != multiplayer.get_unique_id():
				printerr("Error: Received a READY message with dst_peer {dst_peer} during PENDING_READY. Expecting messages destinied to me.".format({ "dst_peer": message.dst_peer }))
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting messages destinied to me.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				continue
			# Else, we have received a valid READY!
			# Close the websocket, and transition to CLOSING.
			_ws.close(1000, "Received READY from server. The session is now on its own.")
			# We don't do a cleanup, since this is the normal path.
			return State.CLOSING
	return State.PENDING_READY

func _process_closing() -> State:
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.State.STATE_CLOSING:
			return State.CLOSING
		WebSocketPeer.State.STATE_CLOSED:
			return State.DISCONNECTED
		WebSocketPeer.State.STATE_CONNECTING:
			printerr("Error: SessionClient is in state CLOSING, but has a STATE_CONNECTING websocket.")
			_cleanup()
			return State.CONNECTING
		WebSocketPeer.State.STATE_OPEN:
			printerr("Error: SessionClient is in state CLOSING, but has a STATE_OPEN websocket.")
			_cleanup()
			return State.ORPHAN
	printerr("Error: Code shouldn't reach here.")
	return State.CLOSING

func _cleanup() -> void:
	multiplayer.multiplayer_peer = null
	_session_code = ""
	return
	
func _handle_peer_connected(connected_peer_id: int) -> bool:
	# If we don't have a multiplayer peer, something must've gone wrong.
	if !multiplayer.has_multiplayer_peer():
		printerr("Error: SessionClient is handling PEER_CONNECTED, but does not have a multiplayer peer.")
		return false
	var multiplayer_peer = multiplayer.multiplayer_peer
		
	var connected_peer: WebRTCPeerConnection = WebRTCPeerConnection.new()
	# If we fail to add this peer, also return false.
	if multiplayer_peer.add_peer(connected_peer, connected_peer_id):
		return false
	# Now we have added a new peer to the mesh.
	# If my id is smaller than the peer, the peer is responsible for sending an offer.
	if multiplayer_peer.get_unique_id() < connected_peer_id:
		return true
	# Else, I am responsible for sending an offer.
	# Time to setup signals, and exchange RELAYs.
	connected_peer.session_description_created.connect(_on_offer_created.bind(connected_peer_id))
	connected_peer.ice_candidate_created.connect(_on_ice_candidate_created.bind(connected_peer_id))
	connected_peer.create_offer()
	return true
	
func _handle_peer_disconnected(disconnected_peer_id: int) -> bool:
	# If we don't have a multiplayer peer, something must've gone wrong.
	if !multiplayer.has_multiplayer_peer():
		printerr("Error: SessionClient is handling PEER_DISCONNECTED, but does not have a multiplayer peer.")
		return false
	var multiplayer_peer = multiplayer.multiplayer_peer
	
	# If we don't have a matching peer, something strange must've happened. But no need to panic: we wanted the peer dead anyway.
	if !multiplayer_peer.has_peer(disconnected_peer_id):
		printerr("Error: SessionClient is handling PEER_DISCONNECTED from a nonexistant peer.")
		# So we return `true`!
		return true
	
	multiplayer_peer.remove_peer(disconnected_peer_id)	
	return true
	
func _handle_relay(peer_id: int, relay_body: String) -> bool:
	var relay: RelayMessage = RelayMessage.from_json(relay_body)
	# If received message wasn't properly formatted, send back an ERROR.
	if !relay:
		printerr("Error: Received a malformed relay. Expecting properly formatted relays.")
		var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting properly formatted relays.").as_json().to_utf8_buffer()
		_ws.put_packet(reply)
		return false
	match relay.type:
		RelayMessage.Type.OFFER:
			if !("type" in relay.body) || (typeof(relay.body["type"]) != Variant.Type.TYPE_STRING) || !("sdp" in relay.body) || (typeof(relay.body["sdp"]) != Variant.Type.TYPE_STRING):
				printerr("Error: Received a malformed OFFER relay. Expecting properly formatted OFFER relays.")
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting properly formatted OFFER relays.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				return false
			return _handle_relay_offer(relay.body["type"], relay.body["sdp"], peer_id)
		RelayMessage.Type.ANSWER:
			if !("type" in relay.body) || (typeof(relay.body["type"]) != Variant.Type.TYPE_STRING) || !("sdp" in relay.body) || (typeof(relay.body["sdp"]) != Variant.Type.TYPE_STRING):
				printerr("Error: Received a malformed ANSWER relay. Expecting properly formatted ANSWER relays.")
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting properly formatted ANSWER relays.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				return false
			return _handle_relay_answer(relay.body["type"], relay.body["sdp"], peer_id)
		RelayMessage.Type.ICE_CANDIDATE:
			if !("media" in relay.body) || (typeof(relay.body["media"]) != Variant.Type.TYPE_STRING) || !("index" in relay.body) || (typeof(relay.body["index"]) != Variant.Type.TYPE_INT) || !("name" in relay.body) || (typeof(relay.body["name"]) != Variant.Type.TYPE_STRING):
				printerr("Error: Received a malformed ICE_CANDIDATE relay. Expecting properly formatted ICE_CANDIDATE relays.")
				var reply = Message.new(Message.Type.ERROR, multiplayer.get_unique_id(), 0, "Expecting properly formatted ICE_CANDIDATE relays.").as_json().to_utf8_buffer()
				_ws.put_packet(reply)
				return false
			return _handle_relay_ice_candidate(relay.body["media"], relay.body["index"], relay.body["name"], peer_id)
	return true

func _handle_relay_offer(type: String, sdp: String, peer_id: int) -> bool:
	# If we don't have a multiplayer peer, something must've gone wrong.
	if !multiplayer.has_multiplayer_peer():
		printerr("Error: SessionClient received an offer, but does not have a multiplayer peer.")
		return false
	var multiplayer_peer = multiplayer.multiplayer_peer
	# If we don't have a matching peer, something must've gone wrong.
	if !multiplayer_peer.has_peer(peer_id):
		printerr("Error: SessionClient received an offer from a nonexistant peer.")
		return false
	# If peer id is smaller than us, we should be the one sending an offer.
	if multiplayer_peer.get_unique_id() > peer_id:
		printerr("Error: SessionClient received an offer from a peer with smaller id.")
		return false
	# Else, we have a valid WebRTCConnection.
	var peer: WebRTCPeerConnection = multiplayer_peer.get_peer(peer_id)["connection"]
	# Time to setup signals, and apply the offer to the remote description.
	peer.session_description_created.connect(_on_answer_created.bind(peer_id))
	peer.ice_candidate_created.connect(_on_ice_candidate_created.bind(peer_id))
	peer.set_remote_description(type, sdp)
	return true
	
func _handle_relay_answer(type: String, sdp: String, peer_id: int) -> bool:
	# If we don't have a multiplayer peer, something must've gone wrong.
	if !multiplayer.has_multiplayer_peer():
		printerr("Error: SessionClient received an answer, but does not have a multiplayer peer.")
		return false
	var multiplayer_peer = multiplayer.multiplayer_peer
	# If we don't have a matching peer, something must've gone wrong.
	if !multiplayer_peer.has_peer(peer_id):
		printerr("Error: SessionClient received an answer from a nonexistant peer.")
		return false
	# If peer id is larger than us, we should be the one sending an answer.
	if multiplayer_peer.get_unique_id() < peer_id:
		printerr("Error: SessionClient received an answer from a peer with larger id.")
		return false
	# Else, we have a valid WebRTCConnection.
	var peer: WebRTCPeerConnection = multiplayer_peer.get_peer(peer_id)["connection"]
	# Time to apply the answer to the remote description.
	peer.set_remote_description(type, sdp)
	return true
	
func _handle_relay_ice_candidate(media: String, index: int, name: String, peer_id: int) -> bool:
	# If we don't have a multiplayer peer, something must've gone wrong.
	if !multiplayer.has_multiplayer_peer():
		printerr("Error: SessionClient received an ice candidate, but does not have a multiplayer peer.")
		return false
	var multiplayer_peer = multiplayer.multiplayer_peer
	# If we don't have a matching peer, something must've gone wrong.
	if !multiplayer_peer.has_peer(peer_id):
		printerr("Error: SessionClient received an ice candidate from a nonexistant peer.")
		return false
	# Else, we have a valid WebRTCConnection.
	var peer: WebRTCPeerConnection = multiplayer_peer.get_peer(peer_id)["connection"]
	if peer.add_ice_candidate(media, index, name):
		printerr("Error: SessionClient failed to add a received ice candidate.")
		return false
	return true
	
func _on_offer_created(type: String, sdp: String, peer_id: int) -> void:
	# If we don't have a multiplayer peer, something must've gone wrong.
	if !multiplayer.has_multiplayer_peer():
		printerr("Error: SessionClient created an offer, but does not have a multiplayer peer.")
		return
	var multiplayer_peer = multiplayer.multiplayer_peer
	# If we don't have a matching peer, something must've gone wrong.
	if !multiplayer_peer.has_peer(peer_id):
		printerr("Error: SessionClient created an offer for a nonexistant peer.")
		return
	# Else, we have a valid WebRTCConnection. Send the offer to the remote peer via RELAY-OFFER, and set local description.
	var peer: WebRTCPeerConnection = multiplayer_peer.get_peer(peer_id)["connection"]
	# First send the offer, so that ice candidates will never arrive faster than the offer.
	var offer = Message.new(Message.Type.RELAY, multiplayer.get_unique_id(), peer_id, RelayMessage.new(RelayMessage.Type.OFFER, { "type": type, "sdp": sdp }).as_json()).as_json().to_utf8_buffer()
	_ws.put_packet(offer)
	# Then set the local description to the offer.
	peer.set_local_description(type, sdp)
	return
	
func _on_answer_created(type: String, sdp: String, peer_id: int) -> void:
	# If we don't have a multiplayer peer, something must've gone wrong.
	if !multiplayer.has_multiplayer_peer():
		printerr("Error: SessionClient created an answer, but does not have a multiplayer peer.")
		return
	var multiplayer_peer = multiplayer.multiplayer_peer
	# If we don't have a matching peer, something must've gone wrong.
	if !multiplayer_peer.has_peer(peer_id):
		printerr("Error: SessionClient created an answer for a nonexistant peer.")
		return
	# Else, we have a valid WebRTCConnection. Send the answer to the remote peer via RELAY-ANSWER, and set local description.
	var peer: WebRTCPeerConnection = multiplayer_peer.get_peer(peer_id)["connection"]
	# First send the answer, so that ice candidates will never arrive faster than the answer.
	var answer = Message.new(Message.Type.RELAY, multiplayer.get_unique_id(), peer_id, RelayMessage.new(RelayMessage.Type.ANSWER, { "type": type, "sdp": sdp }).as_json()).as_json().to_utf8_buffer()
	_ws.put_packet(answer)
	# Then set the local description to the answer.
	peer.set_local_description(type, sdp)
	return
	
func _on_ice_candidate_created(media: String, index: int, name: String, peer_id: int) -> void:
	# If we don't have a multiplayer peer, something must've gone wrong.
	if !multiplayer.has_multiplayer_peer():
		printerr("Error: SessionClient created an ice candidate, but does not have a multiplayer peer.")
		return
	var multiplayer_peer = multiplayer.multiplayer_peer
	# If we don't have a matching peer, something must've gone wrong.
	if !multiplayer_peer.has_peer(peer_id):
		printerr("Error: SessionClient created an ice candidate for a nonexistant peer.")
		return
	# Else, we have a valid WebRTCConnection. Send the ice candidate to the remote peer via RELAY-ICE_CANDIDATE.
	var peer: WebRTCPeerConnection = multiplayer_peer.get_peer(peer_id)["connection"]
	var ice_candidate = Message.new(Message.Type.RELAY, multiplayer.get_unique_id(), peer_id, RelayMessage.new(RelayMessage.Type.ICE_CANDIDATE, { "media": media, "index": index, "name": name }).as_json()).as_json().to_utf8_buffer()
	_ws.put_packet(ice_candidate)
	return
