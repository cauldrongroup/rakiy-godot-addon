extends RefCounted
## Editor helper: install [godotengine/webrtc-native](https://github.com/godotengine/webrtc-native) `godot-extension-webrtc.zip` under `res://addons/webrtc/`.

const _ZIP_ROOT := "webrtc/"


static func delete_addons_webrtc() -> void:
	delete_res_directory("res://addons/webrtc")


static func delete_res_directory(res_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(res_path)
	if not DirAccess.dir_exists_absolute(abs_path):
		return
	_delete_abs_directory(abs_path)


static func _delete_abs_directory(abs_path: String) -> void:
	var d := DirAccess.open(abs_path)
	if d == null:
		return
	d.list_dir_begin()
	var fn := d.get_next()
	while fn != "":
		if fn != "." and fn != "..":
			var full := abs_path.path_join(fn)
			if d.current_is_dir():
				_delete_abs_directory(full)
			else:
				DirAccess.remove_absolute(full)
		fn = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(abs_path)


static func extract_zip_to_addons_webrtc(zip_abs_path: String) -> Error:
	var reader := ZIPReader.new()
	var oerr := reader.open(zip_abs_path)
	if oerr != OK:
		return oerr
	var files := reader.get_files()
	for f in files:
		if f.ends_with("/"):
			continue
		if not f.begins_with(_ZIP_ROOT):
			continue
		var rel := f.substr(_ZIP_ROOT.length())
		var out_res := "res://addons/webrtc/" + rel
		var out_abs := ProjectSettings.globalize_path(out_res)
		DirAccess.make_dir_recursive_absolute(out_abs.get_base_dir())
		var buf := reader.read_file(f)
		var fa := FileAccess.open(out_abs, FileAccess.WRITE)
		if fa == null:
			reader.close()
			return ERR_FILE_CANT_WRITE
		fa.store_buffer(buf)
	reader.close()
	return OK
