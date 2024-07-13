extends VBoxContainer

var ws_peer: WebSocketPeer = WebSocketPeer.new()

func _on_start_client_pressed():
	$StartClient.disabled = true
	$StopClient.disabled = false
	if ws_peer.connect_to_url("ws://localhost:12345"):
		printerr("Error: Failed to connect to url.")
		$StartClient.disabled = false
		$StopClient.disabled = true

func _on_stop_client_pressed():
	ws_peer.close(1000, "Client request.")
	pass # Replace with function body.

func _on_send_pressed():
	var json: String = $Message.text
	
	# If the json isn't a valid message, don't send it.
	if !Message.from_json(json):
		printerr("Error: Attempted to send an invalid message.")
		return
	
	# If `ws_peer` isn't OPEN, can't send.
	if ws_peer.get_ready_state() != WebSocketPeer.State.STATE_OPEN:
		printerr("Error: Attempted to send a message with a non-open websocket.")
		return
	
	if ws_peer.put_packet(json.to_utf8_buffer()):
		printerr("Error: Failed to send a packet.")

func _process(delta):
	ws_peer.poll()
	match ws_peer.get_ready_state():
		WebSocketPeer.State.STATE_CONNECTING:
			print("Client: Websocket is connecting.")
			return
		WebSocketPeer.State.STATE_CLOSING:
			print("Client: Websocket is closing.")
			return
		WebSocketPeer.State.STATE_CLOSED:
			print("Client: Websocket is closed.")
			$StartClient.disabled = false
			$StopClient.disabled = true
			return
		WebSocketPeer.State.STATE_OPEN:
			print("Client: Websocket is open.")
			while ws_peer.get_available_packet_count() != 0:
				var message: String = ws_peer.get_packet().get_string_from_utf8()
				var json = JSON.new()
				var pretty_message = JSON.stringify(json.parse_string(message), "\t")
				$Output.text += pretty_message
				$Output.scroll_vertical = 1.0e100
			return



