extends Node

@onready var session_client: SessionClient = $Background/MarginContainer/App/SessionClientUI/SessionClient

func _ready():
	# If this instance is headless, immediately switch to server.
	if DisplayServer.get_name() == "headless":
		get_tree().call_deferred("change_scene_to_packed", load("res://tests/simple_chat/SimpleChatServer.tscn"))

func _log(log: String) -> void:
	$Background/MarginContainer/App/SessionClientUI/Log.append_text(log+"\n")

func _on_start_as_server_pressed():
	get_tree().change_scene_to_packed(load("res://tests/simple_chat/SimpleChatServer.tscn"))

func _on_host_pressed():
	_log("Host pressed.")
	_log("Attempting to connect to server.")
	var connect_success: bool = await session_client.connect_to_url($Background/MarginContainer/App/SessionClientUI/URLContainer/URL.text)
	if !connect_success:
		_log("Connection to server failed.")
		return
	_log("Connected to server.")
	_log("Attempting to host a session.")
	var session_code: String = await session_client.host()
	if session_code == "":
		_log("Host failed.")
		return
	_log("Hosted a session. Session code is {session_code}".format({"session_code": session_code}))
	$Background/MarginContainer/App/SessionClientUI/SessionCodeContainer/SessionCode.text = session_code
	
	$Background/MarginContainer/App/SessionClientUI/SessionCodeContainer/SessionCode.editable = false
	$Background/MarginContainer/App/SessionClientUI/HostJoinContainer/Host.disabled = true
	$Background/MarginContainer/App/SessionClientUI/HostJoinContainer/Join.disabled = true
	
	$Background/MarginContainer/App/SessionClientUI/Seal.disabled = false
	$Background/MarginContainer/App/SessionClientUI/Leave.disabled = false

func _on_join_pressed():
	_log("Join pressed.")
	_log("Attempting to connect to server.")
	var connect_success: bool = await session_client.connect_to_url($Background/MarginContainer/App/SessionClientUI/URLContainer/URL.text)
	if !connect_success:
		_log("Connection to server failed.")
		return
	_log("Connected to server.")
	_log("Attempting to join a session.")
	var join_success: bool = await session_client.join($Background/MarginContainer/App/SessionClientUI/SessionCodeContainer/SessionCode.text)
	if !join_success:
		_log("Join failed.")
		return
	_log("Joined a session.")
	
	$Background/MarginContainer/App/SessionClientUI/SessionCodeContainer/SessionCode.editable = false
	$Background/MarginContainer/App/SessionClientUI/HostJoinContainer/Host.disabled = true
	$Background/MarginContainer/App/SessionClientUI/HostJoinContainer/Join.disabled = true
	
	$Background/MarginContainer/App/SessionClientUI/Seal.disabled = true
	$Background/MarginContainer/App/SessionClientUI/Leave.disabled = false

func _on_seal_pressed():
	_log("Seal pressed.")
	_log("Attempting to seal the session.")
	var seal_success: bool = await session_client.seal()
	if !seal_success:
		_log("Failed to seal the session.")
		return
	_log("Session sealed.")

func _on_leave_pressed():
	_log("Leave pressed.")
	await session_client.leave()
	_log("Leaved session.")

func _handle_disconnect():
	var ready: bool = await session_client.ready()
	if !ready:
		_log("Disconnected from server (unintended).")
		# We encountered a unwanted disconnection.
		$Background/MarginContainer/App/SessionClientUI/SessionCodeContainer/SessionCode.editable = true
		$Background/MarginContainer/App/SessionClientUI/HostJoinContainer/Host.disabled = false
		$Background/MarginContainer/App/SessionClientUI/HostJoinContainer/Join.disabled = false
		
		$Background/MarginContainer/App/SessionClientUI/Seal.disabled = true
		$Background/MarginContainer/App/SessionClientUI/Leave.disabled = true
		
		$Background/MarginContainer/App/ChatUI/SendContainer/Input.text = ""
		$Background/MarginContainer/App/ChatUI/SendContainer/Input.editable = false
		$Background/MarginContainer/App/ChatUI/SendContainer/Send.disabled = true
		if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
			multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
		return
	_log("Session is now ready.")
	
	$Background/MarginContainer/App/SessionClientUI/SessionCodeContainer/SessionCode.editable = false
	$Background/MarginContainer/App/SessionClientUI/HostJoinContainer/Host.disabled = true
	$Background/MarginContainer/App/SessionClientUI/HostJoinContainer/Join.disabled = true
	
	$Background/MarginContainer/App/SessionClientUI/Seal.disabled = true
	$Background/MarginContainer/App/SessionClientUI/Leave.disabled = false
	
	$Background/MarginContainer/App/ChatUI/PanelContainer/Chat.text = ""
	$Background/MarginContainer/App/ChatUI/SendContainer/Input.text = ""
	$Background/MarginContainer/App/ChatUI/SendContainer/Input.editable = true
	$Background/MarginContainer/App/ChatUI/SendContainer/Send.disabled = false
	if !multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _on_send_pressed():
	var message = $Background/MarginContainer/App/ChatUI/SendContainer/Input.text
	$Background/MarginContainer/App/ChatUI/SendContainer/Input.text = ""
	received_message.rpc(message)
	var bbcode: String = "[right][b]{sender_id}(You): [/b]{message}[/right]\n".format({"sender_id": multiplayer.get_unique_id(),"message": message.replace("[", "[lb]")})
	$Background/MarginContainer/App/ChatUI/PanelContainer/Chat.append_text(bbcode)

@rpc("any_peer", "reliable")
func received_message(message: String) -> void:
	var sender_id: int = multiplayer.get_remote_sender_id()
	var bbcode: String = "[b]{sender_id}: [/b]{message}\n".format({"sender_id": sender_id, "message": message.replace("[", "[lb]")})
	$Background/MarginContainer/App/ChatUI/PanelContainer/Chat.append_text(bbcode)

func _on_peer_disconnected(peer_id: int) -> void:
	var bbcode: String = "[center][b]{peer_id}[/b] leaved the chat.[/center]\n".format({"peer_id": peer_id})
	$Background/MarginContainer/App/ChatUI/PanelContainer/Chat.append_text(bbcode)
