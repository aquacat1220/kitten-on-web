class_name RelayMessage
extends RefCounted

enum Type {
	OFFER, # 'body': Dictionary | Dictionary resembling { "type": <String>, "sdp": <String> }
	ANSWER, # 'body': Dictionary | Dictionary resembling { "type": <String>, "sdp": <String> }
	ICE_CANDIDATE # 'body': Dictionary | Dictionary resembling { "media": <String>, "index": <int>, "name": <String> }
}

var type: Type
# `body` depends on `type`.
var body

func _init(_type: Type, _body) -> void:
	type = _type
	body = _body

func as_json() -> String:
	var dict = {
		"type": RelayMessage.type_to_string(type),
		"body": body
	}
	return JSON.stringify(dict)
	
static func from_json(json_string: String) -> RelayMessage:
	var message = JSON.parse_string(json_string)
	
	if (!message):
		return null
		
	if !("type" in message) || (typeof(message["type"]) != TYPE_STRING):
		return null
	var type = string_to_type(message["type"])
	if !type:
		return null
	
	if !("body" in message):
		return null
	var body = message["body"]
	
	return RelayMessage.new(type, body)

static func type_to_string(type: Type) -> String:
	match type:
		Type.OFFER:
			return "OFFER"
		Type.ANSWER:
			return "ANSWER"
		Type.ICE_CANDIDATE:
			return "ICE_CANDIDATE"
		_:
			return ""
	
static func string_to_type(type_string: String): # -> Type
	match type_string:
		"OFFER":
			return Type.OFFER
		"ANSWER":
			return Type.ANSWER
		"ICE_CANDIDATE":
			return Type.ICE_CANDIDATE
		_:
			return null
