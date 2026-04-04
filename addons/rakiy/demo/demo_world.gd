extends RefCounted
class_name RakiyDemoWorld
## Procedural test arena for the Rakiy demo (floor + rim walls + lighting).


static func build(parent: Node3D) -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.1, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.48, 0.55)
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 38.0, 0.0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	parent.add_child(sun)

	var floor_size := Vector3(48.0, 0.5, 48.0)
	var floor_body := StaticBody3D.new()
	floor_body.position = Vector3(0.0, -0.25, 0.0)
	var floor_mesh := MeshInstance3D.new()
	var box_m := BoxMesh.new()
	box_m.size = floor_size
	floor_mesh.mesh = box_m
	var mat_f := StandardMaterial3D.new()
	mat_f.albedo_color = Color(0.26, 0.3, 0.34)
	floor_mesh.material_override = mat_f
	var floor_cs := CollisionShape3D.new()
	var floor_sh := BoxShape3D.new()
	floor_sh.size = floor_size
	floor_cs.shape = floor_sh
	floor_body.add_child(floor_mesh)
	floor_body.add_child(floor_cs)
	parent.add_child(floor_body)

	var wall_h := 3.5
	var wall_t := 0.45
	var half := 24.0
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.34, 0.38, 0.42)
	for w in [
		[Vector3(0.0, wall_h * 0.5, -half), Vector3(floor_size.x, wall_h, wall_t)],
		[Vector3(0.0, wall_h * 0.5, half), Vector3(floor_size.x, wall_h, wall_t)],
		[Vector3(-half, wall_h * 0.5, 0.0), Vector3(wall_t, wall_h, floor_size.z)],
		[Vector3(half, wall_h * 0.5, 0.0), Vector3(wall_t, wall_h, floor_size.z)],
	]:
		var wb := StaticBody3D.new()
		wb.position = w[0]
		var wm := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = w[1]
		wm.mesh = bm
		wm.material_override = wall_mat
		var wcs := CollisionShape3D.new()
		var ws := BoxShape3D.new()
		ws.size = w[1]
		wcs.shape = ws
		wb.add_child(wm)
		wb.add_child(wcs)
		parent.add_child(wb)
