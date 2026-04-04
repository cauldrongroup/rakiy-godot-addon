class_name RakiyLog
extends RefCounted
## Single logging entry point for the Rakiy addon. Call only these methods from Rakiy code.
## On first use, checks whether global class **GameLog** is registered (e.g. game_log addon).
## If yes, all messages use `GameLog.info` / `warn` / `error`. Otherwise `print` / `push_*`.
## Keep this file identical between **rakiy-godot-addon** and **template-rakiy** `addons/rakiy/`.

static var _use_game_log: bool = false
static var _resolved: bool = false


static func _resolve() -> void:
	if _resolved:
		return
	_resolved = true
	_use_game_log = ClassDB.class_exists(&"GameLog")


static func info(tag: String, msg: Variant) -> void:
	_resolve()
	if _use_game_log:
		ClassDB.class_call_static(&"GameLog", &"info", tag, msg)
		return
	print("[%s] %s" % [tag, msg])


static func warn(tag: String, msg: Variant) -> void:
	_resolve()
	if _use_game_log:
		ClassDB.class_call_static(&"GameLog", &"warn", tag, msg)
		return
	push_warning("%s: %s" % [tag, msg])


static func error(tag: String, msg: Variant) -> void:
	_resolve()
	if _use_game_log:
		ClassDB.class_call_static(&"GameLog", &"error", tag, msg)
		return
	push_error("%s: %s" % [tag, msg])
