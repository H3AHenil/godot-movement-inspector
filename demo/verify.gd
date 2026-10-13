extends SceneTree

var failures := 0
var checks := 0
var captured_steps := 0
var captured_contacts := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failures <= 10:
			printerr("FAIL: ", message)


func _box(parent: Node3D, at: Vector3, size: Vector3, tilt := 0.0) -> void:
	var body := StaticBody3D.new()
	body.position = at
	body.rotation_degrees.x = tilt
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)


func _fixture(kind: String, traced: bool) -> Node3D:
	# Identical coordinates in separate worlds avoid translation-rounding noise.
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(viewport)
	var stage := Node3D.new()
	viewport.add_child(stage)
	_box(stage, Vector3(0, -0.25, 0), Vector3(14, 0.5, 14))
	if kind == "wall" or kind == "corner":
		_box(stage, Vector3(0, 1.5, -3), Vector3(10, 3, 0.4))
	if kind == "corner":
		_box(stage, Vector3(3, 1.5, 0), Vector3(0.4, 3, 6))
	if kind == "ramp30":
		_box(stage, Vector3(0, 1.1, -2), Vector3(3, 0.25, 5), 30.0)
	if kind == "ramp60":
		_box(stage, Vector3(0, 1.65, -2), Vector3(3, 0.25, 4), 60.0)
	var body := CharacterBody3D.new()
	body.name = "Player"
	body.position = Vector3(0, 1.5, 2.5)
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	collision.shape = capsule
	body.add_child(collision)
	stage.add_child(body)
	if body.has_method("set_movement_trace_enabled"):
		body.call("set_movement_trace_enabled", traced)
	return stage


func _run() -> void:
	var probe := CharacterBody3D.new()
	var supported := probe.has_method("get_movement_trace")
	probe.free()
	if not supported:
		printerr("Missing trace API: use the patched editor/debug binary.")
		quit(2)
		return
	for kind in ["floor", "wall", "ramp30", "ramp60", "corner"]:
		var stage_a := _fixture(kind, false)
		var stage_b := _fixture(kind, true)
		var a := stage_a.get_node("Player") as CharacterBody3D
		var b := stage_b.get_node("Player") as CharacterBody3D
		await physics_frame
		await physics_frame
		var saw_wall := false
		var saw_ramp := false
		var saw_multiple := false
		var old_call := -1
		for tick in range(120):
			await physics_frame
			var direction := Vector3.ZERO
			if tick >= 20 and kind != "floor":
				direction = Vector3(0, 0, -1)
				if kind == "corner":
					direction = Vector3(0.5, 0, -1).normalized()
			for body in [a, b]:
				body.velocity.x = direction.x * 5.0
				body.velocity.z = direction.z * 5.0
				body.velocity.y -= 9.8 / 60.0
				body.move_and_slide()
			_check(a.position.distance_to(b.position) < 0.0002, kind + " position changed")
			_check(a.velocity.distance_to(b.velocity) < 0.0002, kind + " velocity changed")
			_check(a.is_on_floor() == b.is_on_floor() and a.is_on_wall() == b.is_on_wall(), kind + " state changed")
			var trace: Dictionary = b.call("get_movement_trace")
			_check(int(trace["call"]) > old_call, "stale trace call")
			old_call = int(trace["call"])
			_check(Vector3(trace["end"]).distance_to(b.global_position) < 0.00001, "end position mismatch")
			var steps: Array = trace["steps"]
			_check(steps.size() <= 64, "trace capacity exceeded")
			saw_multiple = saw_multiple or steps.size() > 1
			for step: Dictionary in steps:
				captured_steps += 1
				saw_wall = saw_wall or bool(step["wall"])
				for contact: Dictionary in step["contacts"]:
					captured_contacts += 1
					if not contact["math_valid"]:
						continue
					var n: Vector3 = contact["normal"].normalized()
					var tangent: Vector3 = contact["tangent_component"]
					var perpendicular: Vector3 = contact["normal_component"]
					_check(absf(n.dot(tangent)) < 0.00001, "projection not tangential")
					_check((tangent + perpendicular).distance_to(step["remainder"]) < 0.00001, "projection reconstruction")
					_check(absf(Vector3(contact["plane_tangent"]).dot(n)) < 0.00001, "basis not perpendicular")
					var angle := float(contact["angle_degrees"])
					_check(is_finite(angle) and angle >= 0 and angle <= 180, "invalid angle")
					var target := 30.0 if kind == "ramp30" else 60.0
					saw_ramp = saw_ramp or absf(angle - target) < 0.5
		if kind in ["wall", "corner", "ramp60"]:
			_check(saw_wall, kind + " never reached wall classification")
		if kind in ["ramp30", "ramp60"]:
			_check(saw_ramp, kind + " never reached expected surface angle")
		if kind == "corner":
			_check(saw_multiple, "corner never produced multiple iterations")
		b.call("set_movement_trace_enabled", false)
		var disabled: Dictionary = b.call("get_movement_trace")
		_check(disabled["steps"].is_empty(), "disable did not clear trace")
		print("Fixture ", kind, ": checked 120 ticks; wall=", saw_wall, "; ramp=", saw_ramp, "; multi-step=", saw_multiple)
		stage_a.get_parent().queue_free()
		stage_b.get_parent().queue_free()
		await physics_frame
	print("RESULT: ", checks, " checks; ", captured_steps, " steps; ", captured_contacts, " contacts; ", failures, " failures.")
	quit(0 if failures == 0 else 1)
