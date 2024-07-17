extends Node

var PORT: int = 12345

func _on_start_server_pressed():
	if !$SessionServer.start(PORT):
		$Background/MarginContainer/StartServer.disabled = true
		$Background/MarginContainer/StartServer.text = "Started server."
		return
	$Background/MarginContainer/StartServer.text = "Failed to start server. Press again to retry."

func _ready():
	var env_port = OS.get_environment("KITTEN_ON_WEB_PORT").to_int()
	if env_port != 0:
		PORT = env_port
		
	# If this instance is headless, immediately start the server.
	if DisplayServer.get_name() == "headless":
		if $SessionServer.start(PORT):
			push_error("Failed to start server at port {PORT}".format({"PORT": PORT}))
			$Background/MarginContainer/StartServer.text = "Failed to start server."
			get_tree().quit()
		$Background/MarginContainer/StartServer.disabled = true
		$Background/MarginContainer/StartServer.text = "Started server."
