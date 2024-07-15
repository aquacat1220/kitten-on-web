extends VBoxContainer

@onready var session_client: SessionClient = $SessionClient

func _on_connect_to_url_pressed():
	var success: bool = await session_client.connect_to_url("ws://localhost:12345")
	if !success:
		print("Connection failed!")
		return
	print("Connection success!")
	return

func _on_host_pressed():
	var session_code: String = await session_client.host()
	if session_code == "":
		print("Host failed!")
		return
	print("Host success! Session code is {session_code}.".format({"session_code":session_code}))
	$SessionCode.text = session_code
	return

func _on_join_pressed():
	var session_code = $SessionCode.text
	var success: bool = await session_client.join(session_code)
	if !success:
		print("Join failed!")
		return
	print("Join success! Session code is {session_code}.".format({"session_code":session_code}))
	return

func _on_seal_pressed():
	var success: bool = await session_client.seal()
	if !success:
		print("Seal failed!")
		return
	print("Seal success!")
	return

func _on_wait_for_ready_pressed():
	var success: bool = await session_client.wait_until_ready()
	if !success:
		print("Wait failed!")
		return
	print("Wait success!")
	return

func _on_leave_pressed():
	await session_client.leave()
	print("Leaved session!")
