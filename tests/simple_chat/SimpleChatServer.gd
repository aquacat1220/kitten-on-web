extends Node

func _on_start_server_pressed():
	if !$SessionServer.start(12345):
		$Background/MarginContainer/StartServer.disabled = true
		$Background/MarginContainer/StartServer.text = "Started server."
		return
	$Background/MarginContainer/StartServer.text = "Failed to start server. Press again to retry."

func _ready():
	# If this instance is headless, immediately start the server.
	if DisplayServer.get_name() == "headless":
		if $SessionServer.start(12345):
			$Background/MarginContainer/StartServer.text = "Failed to start server."
			get_tree().quit()
		$Background/MarginContainer/StartServer.disabled = true
		$Background/MarginContainer/StartServer.text = "Started server."
