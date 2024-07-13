class_name Message
extends RefCounted

enum Type {
	ERROR, # `body`: String | Error description.
	JOIN, # `body`: String | session code.
	PEER_CONNECTED, # `body`: int | connected peer.
	PEER_DISCONNECTED, # `body`: int | disconnected peer.
	SEAL, # `body`: null
	RELAY, # `body`: String | Arbitrary string.
	READY # `body`: null
}

var type: Type
var src_peer: int
var dst_peer: int
# `body` depends on `type`.
var body

func _init(_type: Type, _src_peer: int, _dst_peer: int, _body) -> void:
	type = _type
	src_peer = _src_peer
	dst_peer = _dst_peer
	body = _body

func as_json() -> String:
	var dict = {
		"type": Message.type_to_string(type),
		"src_peer": src_peer,
		"dst_peer": dst_peer,
		"body": body
	}
	return JSON.stringify(dict)
	
static func from_json(json_string: String) -> Message:
	var message = JSON.parse_string(json_string)
	
	if (!message):
		return null
		
	if !("type" in message) || (typeof(message["type"]) != TYPE_STRING):
		return null
	var type = string_to_type(message["type"])
	if !type:
		return null
		
	if !("src_peer" in message) || (typeof(message["src_peer"]) != TYPE_FLOAT):
		return null
	var src_peer: int = message["src_peer"]
	if !("dst_peer" in message) || (typeof(message["dst_peer"]) != TYPE_FLOAT):
		return null
	var dst_peer: int = message["dst_peer"]
	
	if !("body" in message):
		return null
	var body = message["body"]
	
	return Message.new(type, src_peer, dst_peer, body)

static func type_to_string(type: Type) -> String:
	match type:
		Type.ERROR:
			return "ERROR"
		Type.JOIN:
			return "JOIN"
		Type.PEER_CONNECTED:
			return "PEER_CONNECTED"
		Type.PEER_DISCONNECTED:
			return "PEER_DISCONNECTED"
		Type.SEAL:
			return "SEAL"
		Type.RELAY:
			return "RELAY"
		Type.READY:
			return "READY"
		_:
			return ""
	
static func string_to_type(type_string: String): # -> Type
	match type_string:
		"ERROR":
			return Type.ERROR
		"JOIN":
			return Type.JOIN
		"PEER_CONNECTED":
			return Type.PEER_CONNECTED
		"PEER_DISCONNECTED":
			return Type.PEER_DISCONNECTED
		"SEAL":
			return Type.SEAL
		"RELAY":
			return Type.RELAY
		"READY":
			return Type.READY
		_:
			return null
	
