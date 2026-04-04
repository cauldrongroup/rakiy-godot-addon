class_name RakiyLog
extends RefCounted
## Routes Rakiy messages through [GameLog] when that addon is present; otherwise uses print / push_*.

static func info(tag: String, msg: Variant) -> void:
	if ClassDB.class_exists("GameLog"):
		ClassDB.class_call_static("GameLog", "info", tag, msg)
	else:
		print("[%s] %s" % [tag, msg])


static func warn(tag: String, msg: Variant) -> void:
	if ClassDB.class_exists("GameLog"):
		ClassDB.class_call_static("GameLog", "warn", tag, msg)
	else:
		push_warning("%s: %s" % [tag, msg])


static func error(tag: String, msg: Variant) -> void:
	if ClassDB.class_exists("GameLog"):
		ClassDB.class_call_static("GameLog", "error", tag, msg)
	else:
		push_error("%s: %s" % [tag, msg])
