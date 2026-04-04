extends CharacterBody3D

## Simple FPS movement for the Rakiy demo; pose is serialized via RakiyPack (position + yaw + pitch).

const SPEED := 7.0
const JUMP_VELOCITY := 5.5
const MOUSE_SENS := 0.0022

@onready var camera: Camera3D = $Camera3D

var _name_label: Label3D


func _ready() -> void:
	camera.current = true
	# Local player: hide own capsule mesh so the view is first-person.
	var mesh: MeshInstance3D = get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh:
		mesh.visible = false

	_name_label = Label3D.new()
	_name_label.text = ""
	_name_label.font_size = 28
	_name_label.pixel_size = 0.0065
	_name_label.position = Vector3(0.0, 1.92, 0.0)
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.no_depth_test = true
	_name_label.outline_size = 10
	_name_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
	_name_label.modulate = Color(0.85, 1.0, 0.85, 1.0)
	add_child(_name_label)


func set_username(username: String) -> void:
	if _name_label:
		_name_label.text = username


func _unhandled_input(event: InputEvent) -> void:
	# Esc / pause menu is handled by DemoMain so the arena stays full-screen in a lobby.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENS)
		camera.rotate_x(-event.relative.y * MOUSE_SENS)
		camera.rotation.x = clampf(camera.rotation.x, deg_to_rad(-88.0), deg_to_rad(88.0))


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	var dir2 := _get_move_vector()
	var dir := (transform.basis * Vector3(dir2.x, 0.0, dir2.y)).normalized()
	if dir:
		velocity.x = dir.x * SPEED
		velocity.z = dir.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
		velocity.z = move_toward(velocity.z, 0.0, SPEED)
	if Input.is_physical_key_pressed(KEY_SPACE) and is_on_floor():
		velocity.y = JUMP_VELOCITY
	move_and_slide()


func _get_move_vector() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		v.y += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		v.x += 1.0
	return v.normalized() if v.length_squared() > 0.0 else Vector2.ZERO


func get_pose_dict() -> Dictionary:
	return {
		"p": global_position,
		"y": rotation.y,
		"pitch": camera.rotation.x,
	}
