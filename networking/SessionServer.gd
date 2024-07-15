class_name SessionServer
extends Node

# `_listen_server` is the TCP server listening for new websocket connections.
var _listen_server: TCPServer = TCPServer.new()
# `_orphans` is an array of WebSocketPeers that didn't `join` a session yet.
var _orphans: Array[WebSocketPeer] = []
# `_open_sessions` is a dictionary from session code (String) to a dictionary from peer id (int) to WebSocketPeers of that session.
var _open_sessions: Dictionary = {}
# `_sealed_sessions`is a dictionary from session code (String) to a a dictionary from peer id (int) to a length-2 array of WebSocketPeer and its readiness.
var _sealed_sessions: Dictionary = {}

func start(listen_port: int) -> Error:
	return _listen_server.listen(listen_port)

func is_listening() -> bool:
	return _listen_server.is_listening()

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta) -> void:
	# If `listen_server` is not listening, the server isn't started yet, and `listen()` should be called first.
	if !_listen_server.is_listening():
		return
		
	# Else, we can start the server.
	
	# First, check `listen_server` for connection attempts.
	while _listen_server.is_connection_available():
		var orphan = WebSocketPeer.new()
		# If `accept_stream()` fails for some reason, ignore this stream. The client will retry if it is desperate.
		if orphan.accept_stream(_listen_server.take_connection()):
			push_error("Error: Failed to accept a stream.")
			continue
		_orphans.append(orphan)
	
	# Removing elements while iterating over a container is unsound!
	# Deepcopy `orphans` into `old_orphans`, and iterate over it instead.
	var old_orphans: Array[WebSocketPeer] = _orphans.duplicate(true)
	# Poll orphans to make sure they are connected, and possibly process `JOIN`s.
	for orphan in old_orphans:
		orphan.poll()
		match orphan.get_ready_state():
			# Not connected yet. Wait until fully connected.
			WebSocketPeer.State.STATE_CONNECTING:
				continue
			# In process of closing. Wait until fully closed.
			WebSocketPeer.State.STATE_CLOSING:
				continue
			# Closed socket. Remove from `orphans`.
			WebSocketPeer.State.STATE_CLOSED:
				_orphans.erase(orphan)
				continue
			# Open and healthy socket. Read packets from it. (Expecting JOINs.)
			WebSocketPeer.State.STATE_OPEN:
				while orphan.get_available_packet_count() != 0:
					var json_string = orphan.get_packet().get_string_from_utf8()
					debug_print(json_string)
					var message = Message.from_json(json_string)
					# If received message wasn't properly formatted, send back an ERROR.
					if !message:
						push_error("Error: Received a malformed message from an orphan. Expecting properly formatted messages.")
						var reply = Message.new(Message.Type.ERROR, 0, 0, "Expecting properly formatted messages.").as_json().to_utf8_buffer()
						orphan.put_packet(reply)
						continue
					# If received message is a ERROR, push_error.
					if message.type == Message.Type.ERROR:
						push_error("Error: Received a ERROR message from an orphan. Error body was: {body}".format({ "body": message.body }))
						continue
					# If received message isn't a JOIN with 0 0 peer ids, send back an ERROR.
					if (message.type != Message.Type.JOIN) || (message.src_peer != 0) || (message.dst_peer != 0):
						push_error("Error: Received a non-JOIN message from an orphan. Expecting JOIN messages from orphans.")
						var reply = Message.new(Message.Type.ERROR, 0, 0, "Expecting JOIN messages from orphans.").as_json().to_utf8_buffer()
						orphan.put_packet(reply)
						# Keep processing packets until we meet a valid JOIN.
						continue
					# Else, the message is a JOIN. Join or host an appropriate session.
					# `body` of a JOIN denotes the session code.
					# Session code of "" denotes a HOST. Create a new open session and move this orphan to it.
					if message.body == "":
						var session_code = SessionServer._random_string()
						while (session_code in _open_sessions) || (session_code in _sealed_sessions):
							session_code = SessionServer._random_string()
						var open_session = { 1: orphan }
						_orphans.erase(orphan)
						_open_sessions[session_code] = open_session
						var reply = Message.new(Message.Type.JOIN, 0, 1, session_code).as_json().to_utf8_buffer()
						orphan.put_packet(reply)
						break
					# Session code other than "" denotes a JOIN.
					else:
						var session_code = message.body
						# If no matching session is found, reply with an ERROR.
						if !(session_code in _open_sessions):
							push_error("Error: Received a JOIN to a nonexistant session from an orphan. Expecting JOIN message bodies to contain codes for existing sessions, or an empty string. \"{session_code}\" was neither of two.")
							var reply = Message.new(Message.Type.ERROR, 0, 0, "Expecting JOIN message bodies to contain codes for existing sessions, or an empty string. \"{session_code}\" was neither of two.".format({"session_code": session_code})).as_json().to_utf8_buffer()
							orphan.put_packet(reply)
							continue
						# Else, we have a matching session. Move this orphan to it, and notify all session members.
						var open_session = _open_sessions[session_code]
						var peer_id = randi_range(1, 1<<31 -1)
						while (peer_id in open_session) || (peer_id == 0):
							peer_id = randi_range(1, 1<<31 -1)
						_orphans.erase(orphan)
						open_session[peer_id] = orphan
						var reply = Message.new(Message.Type.JOIN, 0, peer_id, session_code).as_json().to_utf8_buffer()
						orphan.put_packet(reply)
						_notify_peer_connected(open_session, peer_id)
						break
	
	# Now poll all peers logically part of an open session.
	for session_code in _open_sessions.keys():
		# Previous iterations may removed the session. Check if the session is still there.
		if !(session_code in _open_sessions):
			continue
		var open_session = _open_sessions[session_code]
		for peer_id in open_session.keys():
			# Previous iterations may removed the session, or the peer. Check if this peer is still part of an open session.
			if !(session_code in _open_sessions):
				# The session is no longer open. Break the loop.
				break
			if !(peer_id in open_session):
				# The peer is no longer part of this session. Skip the iteration.
				continue
			# The peer is logically part of a open session.
			var peer: WebSocketPeer = open_session[peer_id]
			peer.poll()
			match peer.get_ready_state():
				# This is not possible: the peer should be pushed to STATE_OPEN during orphan stage.
				WebSocketPeer.State.STATE_CONNECTING:
					push_error("Error: Found a peer of an open session in STATE_CONNECTING.")
					continue
				# In process of closing, or already closed. If this peer isn't a host, notify its disconnection. If it is a host, disconnect all peers and move them to orphans.
				WebSocketPeer.State.STATE_CLOSING, WebSocketPeer.State.STATE_CLOSED:
					# `peer` isn't a host. Notify its disconnection, and move it to `orphans`.
					if peer_id != 1:
						open_session.erase(peer_id)
						_orphans.append(peer)
						_notify_peer_disconnected(open_session, peer_id)
						continue
					# Else, `peer` is the host. Close all peers, and move them to `orphans`.
					_open_sessions.erase(session_code)
					for other_peer_id in open_session:
						var other_peer = open_session[other_peer_id]
						other_peer.close(1000, "Host disconnected.")
						_orphans.append(other_peer)
					continue
				# Open socket. Read packets from it.
				WebSocketPeer.State.STATE_OPEN:
					while peer.get_available_packet_count() != 0:
						var json_string = peer.get_packet().get_string_from_utf8()
						debug_print(json_string)
						var message = Message.from_json(json_string)
						# If received message wasn't properly formatted, send back an ERROR.
						if !message:
							push_error("Error: Received a malformed message from peer {peer_id} of an open session \"{session_code}\". Expecting properly formatted messages.".format({"peer_id": peer_id, "session_code": session_code }))
							var reply = Message.new(Message.Type.ERROR, 0, peer_id, "Expecting properly formatted messages.").as_json().to_utf8_buffer()
							peer.put_packet(reply)
							continue
						# If received message is a ERROR, push_error.
						if message.type == Message.Type.ERROR:
							push_error("Error: Received a ERROR message from peer {peer_id} of an open session \"{session_code}\". Error body was: {body}".format({ "peer_id": peer_id, "session_code": session_code, "body": message.body }))
							continue
						# If received message isn't a SEAL or a RELAY, send back an ERROR.
						if (message.type != Message.Type.SEAL) && (message.type != Message.Type.RELAY):
							push_error("Error: Received a non-SEAL/RELAY message from peer {peer_id} of an open session \"{session_code}\". Expecting SEAL or RELAY messages from a peer of an open session.".format({"peer_id": peer_id, "session_code": session_code }))
							var reply = Message.new(Message.Type.ERROR, 0, peer_id, "Expecting SEAL or RELAY messages from a peer of an open session.").as_json().to_utf8_buffer()
							peer.put_packet(reply)
							continue
						# If `src_peer` is trying to impersonate someone else, send back an ERROR.
						if message.src_peer != peer_id:
							push_error("Error: Received a message with src_peer {src_peer} from peer {peer_id} of an open session \"{session_code}\". Expecting messages to have src_peer matching its peer id.".format({"src_peer": message.src_peer, "peer_id": peer_id, "session_code": session_code }))
							var reply = Message.new(Message.Type.ERROR, 0, peer_id, "Expecting messages to have src_peer matching its peer id.").as_json().to_utf8_buffer()
							peer.put_packet(reply)
							continue
						# Process SEALs.
						if message.type == Message.Type.SEAL:
							# If the SEAL is not from a host, or not for the server, send back an ERROR.
							if (message.src_peer != 1) || (message.dst_peer != 0):
								push_error("Error: Received a SEAL message with src_peer {src_peer} and dst_peer {dst_peer} from peer {peer_id} of an open session \"{session_code}\". Expecting SEAL messages to have src_peer of 1 (the host) and dst_peer of 0 (the server).".format({"src_peer": message.src_peer, "dst_peer": message.dst_peer, "peer_id": peer_id, "session_code": session_code }))
								var reply = Message.new(Message.Type.ERROR, 0, peer_id, "Expecting SEAL messages to have src_peer of 1 (the host) and dst_peer of 0 (the server).").as_json().to_utf8_buffer()
								peer.put_packet(reply)
								continue
							# Else, the SEAL *is* from the host. Move the session to `sealed_sessions`, and notify seal.
							_open_sessions.erase(session_code)
							var sealed_session = SessionServer._into_sealed_session(open_session)
							_sealed_sessions[session_code] = sealed_session
							_notify_seal(sealed_session)
							break
						# Process RELAYs.
						if message.type == Message.Type.RELAY:
							# If the RELAY has an invalid dst_peer, send back an ERROR.
							if !(message.dst_peer in open_session):
								push_error("Error: Received a RELAY message with dst_peer {dst_peer} from peer {peer_id} of an open session \"{session_code}\". Expecting RELAY messages to have valid dst_peer ids.".format({"dst_peer": message.dst_peer, "peer_id": peer_id, "session_code": session_code }))
								var reply = Message.new(Message.Type.ERROR, 0, peer_id, "Expecting RELAY messages to have valid dst_peer ids.").as_json().to_utf8_buffer()
								peer.put_packet(reply)
								continue
							# Else, the RELAY has a valid destination. Send it.
							var dst_peer: WebSocketPeer = open_session[message.dst_peer]
							var relay = message.as_json().to_utf8_buffer()
							dst_peer.put_packet(relay)
							continue
	
	# Finally, poll all peers logically part of a sealed session.
	for session_code in _sealed_sessions.keys():
		# Previous iterations may removed the session. Check if the session is still there.
		if !(session_code in _sealed_sessions):
			continue
		var sealed_session = _sealed_sessions[session_code]
		for peer_id in sealed_session.keys():
			# Previous iterations may removed the session, or the peer. Check if this peer is still part of a sealed session.
			if !(session_code in _sealed_sessions):
				# The session is no longer sealed. Break the loop.
				break
			if !(peer_id in sealed_session):
				# The peer is no longer part of this session. Skip the iteration.
				continue
			# The peer is logically part of a sealed session.
			var peer: WebSocketPeer = sealed_session[peer_id][0]
			peer.poll()
			match peer.get_ready_state():
				# This is not possible: the peer should be pushed to STATE_OPEN during orphan stage.
				WebSocketPeer.State.STATE_CONNECTING:
					push_error("Error: Found a peer of a sealed session in STATE_CONNECTING.")
					continue
				# In process of closing, or already closed.
				WebSocketPeer.State.STATE_CLOSING, WebSocketPeer.State.STATE_CLOSED:
					# Handle disconnections the same way with open sessions.
					# If `peer` isn't a host, notify its disconnection, and move it to `orphans`.
					if peer_id != 1:
						sealed_session.erase(peer_id)
						_orphans.append(peer)
						_notify_peer_disconnected(sealed_session, peer_id)
						continue
					# Else, `peer` is the host. Close all peers, and move them to `orphans`.
					_sealed_sessions.erase(session_code)
					for other_peer_id in sealed_session:
						var other_peer = sealed_session[other_peer_id][0]
						other_peer.close(1000, "Host disconnected.")
						_orphans.append(other_peer)
					continue
				# Open socket. Read packets from it.
				WebSocketPeer.State.STATE_OPEN:
					while peer.get_available_packet_count() != 0:
						var json_string = peer.get_packet().get_string_from_utf8()
						debug_print(json_string)
						var message = Message.from_json(json_string)
						# If received message wasn't properly formatted, send back an ERROR.
						if !message:
							push_error("Error: Received a malformed message from peer {peer_id} of a sealed session \"{session_code}\". Expecting properly formatted messages.".format({"peer_id": peer_id, "session_code": session_code }))
							var reply = Message.new(Message.Type.ERROR, 0, peer_id, "Expecting properly formatted messages.").as_json().to_utf8_buffer()
							peer.put_packet(reply)
							continue
						# If received message is a ERROR, push_error.
						if message.type == Message.Type.ERROR:
							push_error("Error: Received a ERROR message from peer {peer_id} of a sealed session \"{session_code}\". Error body was: {body}".format({ "peer_id": peer_id, "session_code": session_code, "body": message.body }))
							continue
						# If received message isn't a READY or a RELAY, send back an ERROR.
						if (message.type != Message.Type.READY) && (message.type != Message.Type.RELAY):
							push_error("Error: Received a non-READY/RELAY message from peer {peer_id} of a sealed session \"{session_code}\". Expecting READY or RELAY messages from a peer of an sealed session.".format({"peer_id": peer_id, "session_code": session_code }))
							var reply = Message.new(Message.Type.ERROR, 0, peer_id, "Expecting READY or RELAY messages from a peer of an sealed session.").as_json().to_utf8_buffer()
							peer.put_packet(reply)
							continue
						# If `src_peer` is trying to impersonate someone else, send back an ERROR.
						if message.src_peer != peer_id:
							push_error("Error: Received a message with src_peer {src_peer} from peer {peer_id} of a sealed session \"{session_code}\". Expecting messages to have src_peer matching its peer id.".format({"src_peer": message.src_peer, "peer_id": peer_id, "session_code": session_code }))
							var reply = Message.new(Message.Type.ERROR, 0, peer_id, "Expecting messages to have src_peer matching its peer id.").as_json().to_utf8_buffer()
							peer.put_packet(reply)
							continue
						# Process READYs.
						if message.type == Message.Type.READY:
							# If the READY is not for the server, send back an ERROR.
							if message.dst_peer != 0:
								push_error("Error: Received a READY message with dst_peer {dst_peer} from peer {peer_id} of a sealed session \"{session_code}\". Expecting READY messages to have dst_peer of 0 (the server).".format({"dst_peer": message.dst_peer, "peer_id": peer_id, "session_code": session_code }))
								var reply = Message.new(Message.Type.ERROR, 0, peer_id, "Expecting READY messages to have dst_peer of 0 (the server).").as_json().to_utf8_buffer()
								peer.put_packet(reply)
								continue
							# Else, the READY is valid. Set the readiness of this peer to `true`.
							sealed_session[peer_id][1] = true
							continue
						# Process RELAYs.
						if message.type == Message.Type.RELAY:
							# If the RELAY has an invalid dst_peer, send back an ERROR.
							if !(message.dst_peer in sealed_session):
								push_error("Error: Received a RELAY message with dst_peer {dst_peer} from peer {peer_id} of a sealed session \"{session_code}\". Expecting RELAY messages to have valid dst_peer ids.".format({"dst_peer": message.dst_peer, "peer_id": peer_id, "session_code": session_code }))
								var reply = Message.new(Message.Type.ERROR, 0, peer_id, "Expecting RELAY messages to have valid dst_peer ids.").as_json().to_utf8_buffer()
								peer.put_packet(reply)
								continue
							# Else, the RELAY has a valid destination. Send it.
							var dst_peer: WebSocketPeer = sealed_session[message.dst_peer][0]
							var relay = message.as_json().to_utf8_buffer()
							dst_peer.put_packet(relay)
							continue
		# Now, lets check if we should notify READY for this sealed session.
		# First, check if we still have the session. (Though we don't have any code that may remove this session...)
		if !(session_code in _sealed_sessions):
			continue
		# Then, check if all peers of this session are STATE_OPEN, and are ready.
		var can_proceed: bool = true
		for peer_id in sealed_session:
			var peer = sealed_session[peer_id][0]
			var is_ready = sealed_session[peer_id][1]
			# poll `peer` to update ready state.
			peer.poll()
			if (peer.get_ready_state() != WebSocketPeer.State.STATE_OPEN) || (!is_ready):
				can_proceed = false
				break
		if !can_proceed:
			continue
		# After all these checks, we can call `notify_ready()`. Still, if a peer disconnects between the check and the call, the call might fail. But we ignore this case.
		_notify_ready(sealed_session)
		# Finally, we can move all peers of `sealed_session` to orphans, and wait them to close.
		_sealed_sessions.erase(session_code)
		for peer_id in sealed_session:
			var peer = sealed_session[peer_id][0]
			_orphans.append(peer)
	
	
# Iterate over all peers of `session`, and send them a PEER_CONNECTED with the `connected_peer_id`.
# The peer with `connected_peer_id` does not get a PEER_CONNCETED of itself, but instead gets PEER_CONNECTED of all other peers.
func _notify_peer_connected(session: Dictionary, connected_peer_id: int) -> void:
	for peer_id in session:
		# `session` might be open or sealed, and sealed sessions hold a length-2 array where the first element is the peer.
		var peer = session[peer_id]
		if typeof(peer) == Variant.Type.TYPE_ARRAY:
			peer = peer[0]
		# Send PEER_CONNECTED to all other STATE_OPEN peers.
		if (peer_id != connected_peer_id) && (peer.get_ready_state() == WebSocketPeer.State.STATE_OPEN):
			var peer_conn = Message.new(Message.Type.PEER_CONNECTED, 0, peer_id, connected_peer_id).as_json().to_utf8_buffer()
			peer.put_packet(peer_conn)
			continue
		for other_peer_id in session:
			if other_peer_id != peer_id:
				var peer_conn = Message.new(Message.Type.PEER_CONNECTED, 0, peer_id, other_peer_id).as_json().to_utf8_buffer()
				peer.put_packet(peer_conn)

func _notify_peer_disconnected(session: Dictionary, disconnected_peer_id: int) -> void:
	for peer_id in session:
		# `session` might be open or sealed, and sealed sessions hold a length-2 array where the first element is the peer.
		var peer = session[peer_id]
		if typeof(peer) == Variant.Type.TYPE_ARRAY:
			peer = peer[0]
		# Send PEER_DISCONNECTED to all other STATE_OPEN peers.
		if (peer_id != disconnected_peer_id) && (peer.get_ready_state() == WebSocketPeer.State.STATE_OPEN):
			var peer_disconn = Message.new(Message.Type.PEER_DISCONNECTED, 0, peer_id, disconnected_peer_id).as_json().to_utf8_buffer()
			peer.put_packet(peer_disconn)
			continue
		# No need to send anything to the disconnected peer; it isn't even possible anyway.

func _notify_seal(sealed_session: Dictionary) -> void:
	for peer_id in sealed_session:
		var peer = sealed_session[peer_id][0]
		if peer.get_ready_state() == WebSocketPeer.State.STATE_OPEN:
			var sealed = Message.new(Message.Type.SEAL, 0, peer_id, null).as_json().to_utf8_buffer()
			peer.put_packet(sealed)

func _notify_ready(sealed_session: Dictionary) -> void:
	for peer_id in sealed_session:
		var peer = sealed_session[peer_id][0]
		if peer.get_ready_state() == WebSocketPeer.State.STATE_OPEN:
			var ready = Message.new(Message.Type.READY, 0, peer_id, null).as_json().to_utf8_buffer()
			peer.put_packet(ready)
		else:
			push_error("Error: `sealed_session` has a non-OPEN peer.")
		

static func _into_sealed_session(open_session: Dictionary) -> Dictionary:
	var sealed_session: Dictionary = {}
	for peer_id in open_session:
		sealed_session[peer_id] = [open_session[peer_id], false]
	return sealed_session

	
static var _alphanumerals = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

static func _random_string() -> String:
	var random_string: String = ""
	var length = len(_alphanumerals)
	for i in range(16):
		random_string += _alphanumerals[randi() % length]
	return random_string
	
func debug_print(str: String) -> void:
	# print(str)
	pass
