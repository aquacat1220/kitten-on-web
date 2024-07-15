extends VBoxContainer

func _on_start_server_pressed():
	$SessionServer.start(12345)
