extends Node3D

## Other players: capsule mesh + smooth interpolation toward network pose.

const LERP_POS := 14.0
const LERP_YAW := 12.0

var _target_pos: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _mesh: MeshInstance3D
var _name_label: Label3D


func _ready() -> void:
	_mesh = MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.35
	cap.height = 1.6
	_mesh.mesh = cap
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.65, 1.0, 1.0)
	_mesh.material_override = mat
	add_child(_mesh)
	_mesh.position.y = 0.8

	_name_label = Label3D.new()
	_name_label.text = ""
	_name_label.font_size = 28
	_name_label.pixel_size = 0.0065
	_name_label.position = Vector3(0.0, 1.92, 0.0)
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.no_depth_test = true
	_name_label.outline_size = 10
	_name_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
	_name_label.modulate = Color(1.0, 1.0, 1.0, 1.0)
	add_child(_name_label)


func set_username(username: String) -> void:
	if _name_label:
		_name_label.text = username


func set_peer_color(col: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	if _mesh:
		_mesh.material_override = mat


func apply_network_state(state: Dictionary) -> void:
	var pv: Variant = state.get("p", Vector3.ZERO)
	if pv is Vector3:
		_target_pos = pv as Vector3
	elif pv is Array:
		var a: Array = pv
		if a.size() >= 3:
			_target_pos = Vector3(float(a[0]), float(a[1]), float(a[2]))
	_target_yaw = float(state.get("y", state.get("yaw", 0.0)))


func snap_to_network_state(state: Dictionary) -> void:
	apply_network_state(state)
	global_position = _target_pos
	rotation.y = _target_yaw


func _process(delta: float) -> void:
	global_position = global_position.lerp(_target_pos, LERP_POS * delta)
	rotation.y = lerp_angle(rotation.y, _target_yaw, LERP_YAW * delta)
