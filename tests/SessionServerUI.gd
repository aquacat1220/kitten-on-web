extends VBoxContainer

func _on_start_server_pressed():
	$SessionServer.start(12345)
	
func _process(delta):
	if $SessionServer.is_listening():
		print("Server: Server is listening.")
