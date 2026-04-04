@tool
extends EditorPlugin

const _MENU_NAME := "Download / update WebRTC native (GitHub latest)"
const _INSTALLER := preload("res://addons/rakiy/webrtc_native_installer.gd")
const _GITHUB_API := "https://api.github.com/repos/godotengine/webrtc-native/releases/latest"

var _http: HTTPRequest
## "api" while waiting for releases/latest JSON; "zip" while downloading the asset.
var _phase: String = ""

func _enter_tree() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_http_request_completed)
	add_tool_menu_item(_MENU_NAME, _on_menu_webrtc)


func _exit_tree() -> void:
	remove_tool_menu_item(_MENU_NAME)
	if _http:
		_http.queue_free()
		_http = null


func _on_menu_webrtc() -> void:
	if _phase != "":
		RakiyLog.warn("Rakiy", "WebRTC download already in progress.")
		return
	_phase = "api"
	var err := _http.request(
		_GITHUB_API,
		["User-Agent: RakiyGodotEditorPlugin", "Accept: application/vnd.github+json"],
	)
	if err != OK:
		_phase = ""
		RakiyLog.error("Rakiy", "GitHub API request failed: %s" % error_string(err))


func _on_http_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
) -> void:
	if _phase == "api":
		if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
			_phase = ""
			RakiyLog.error("Rakiy", "GitHub API failed (result=%s, HTTP %s)" % [result, response_code])
			return
		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK:
			_phase = ""
			RakiyLog.error("Rakiy", "Invalid JSON from GitHub API.")
			return
		var data: Variant = j.data
		if typeof(data) != TYPE_DICTIONARY:
			_phase = ""
			return
		var url := _pick_extension_zip_url(data as Dictionary)
		if url.is_empty():
			_phase = ""
			RakiyLog.error("Rakiy", "Latest release has no suitable godot-extension-webrtc zip asset.")
			return
		_phase = "zip"
		var err := _http.request(url)
		if err != OK:
			_phase = ""
			RakiyLog.error("Rakiy", "Could not start download: %s" % error_string(err))
		return

	if _phase == "zip":
		_phase = ""
		if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
			RakiyLog.error("Rakiy", "Download failed (result=%s, HTTP %s)" % [result, response_code])
			return
		var zip_path := "user://rakiy_godot_extension_webrtc.zip"
		var wf := FileAccess.open(zip_path, FileAccess.WRITE)
		if wf == null:
			RakiyLog.error("Rakiy", "Cannot write %s" % zip_path)
			return
		wf.store_buffer(body)
		wf.close()
		var abs_zip := ProjectSettings.globalize_path(zip_path)
		_INSTALLER.delete_addons_webrtc()
		var ex := _INSTALLER.extract_zip_to_addons_webrtc(abs_zip)
		if ex != OK:
			RakiyLog.error("Rakiy", "Extract failed: %s" % error_string(ex))
			return
		RakiyLog.info(
			"Rakiy",
			"WebRTC native GDExtension installed under res://addons/webrtc/ — rescanning filesystem."
		)
		get_editor_interface().get_resource_filesystem().scan()


func _pick_extension_zip_url(release: Dictionary) -> String:
	var assets: Array = release.get("assets", [])
	var fallback := ""
	for a in assets:
		if typeof(a) != TYPE_DICTIONARY:
			continue
		var ad: Dictionary = a
		var name: String = str(ad.get("name", ""))
		if not name.ends_with(".zip"):
			continue
		if name == "godot-extension-webrtc.zip":
			return str(ad.get("browser_download_url", ""))
		if "gdnative" in name:
			continue
		if "extension" in name and "webrtc" in name:
			fallback = str(ad.get("browser_download_url", ""))
	return fallback
