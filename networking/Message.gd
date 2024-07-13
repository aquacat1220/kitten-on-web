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

func _init(type: Type, src_peer: int, dst_peer: int, body) -> void:
	type = type
	src_peer = src_peer
	dst_peer = dst_peer
	body = body

func as_json() -> String:
	var dict = {
		"type": type,
		"src_peer": src_peer,
		"dst_peer": dst_peer,
		"body": body
	}
	return JSON.stringify(dict)
	
static func from_json(json_string: String) -> Message:
	var json = JSON.new()
	var message = json.parse_string(json_string)
	if !message:
		return null
	return Message.new(message["type"], message["src_peer"], message["dst_peer"], message["body"])
