class_name Join
extends RefCounted

signal _completed
var _left_signals: int

func all() -> void:
	while _left_signals != 0:
		await _completed
	return
	
func any() -> void:
	if _left_signals >= len(_signals):
		await _completed
	return

var _signals: Array[Signal]

func _init(signals: Array[Signal]):
	_signals = signals
	_left_signals = len(signals)
	for _signal in _signals:
		_signal.connect(_on_signal, Object.ConnectFlags.CONNECT_ONE_SHOT)

func _on_signal():
	_left_signals -= 1
	_completed.emit()
