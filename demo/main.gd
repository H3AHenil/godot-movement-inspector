extends Node3D

const SPEED := 5.0
const GRAVITY := 9.8
const MOTION_SCALE := 12.0
const CYAN := Color(0.15, 0.85, 1.0)
const GREEN := Color(0.35, 1.0, 0.5)
const GOLD := Color(1.0, 0.75, 0.2)
const MAGENTA := Color(1.0, 0.4, 0.85)

@onready var player: CharacterBody3D = $TraceCharacter
@onready var wire_node: MeshInstance3D = $WireNode
@onready var info: Label = $CanvasLayer/PanelContainer/VBoxContainer/InfoLabel
@onready var status: Label = $CanvasLayer/PanelContainer/VBoxContainer/StatusLabel

var wire_mesh := ImmediateMesh.new()
var wire_material := StandardMaterial3D.new()
var trace: Dictionary = {}
var frozen := false
var tracing := true
var available := false
var selected_step := 0
var selected_contact := 0
var reset_pending := true
var spawn_position := Vector3(0, 2, 4)
var settle_ticks := 0
var auto_freeze := false


func _ready() -> void:
	wire_node.mesh = wire_mesh
	wire_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wire_material.vertex_color_use_as_albedo = true
	wire_material.no_depth_test = true
	$Camera3D.look_at(Vector3(1, 0, -1))
	available = player.has_method("get_movement_trace")
	if not available:
		info.text = "Custom C++ API not found.\n\nOpen this project with your\npatched Godot editor binary.\n\nThe stock editor can show the\nroom but cannot capture traces."
		return
	player.call("set_movement_trace_enabled", true)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_F:
			frozen = not frozen
		KEY_T:
			tracing = not tracing
			if available:
				player.call("set_movement_trace_enabled", tracing)
			trace = {}
		KEY_C:
			auto_freeze = not auto_freeze
		KEY_BRACKETLEFT:
			selected_step = maxi(selected_step - 1, 0)
			selected_contact = 0
		KEY_BRACKETRIGHT:
			selected_step += 1
			selected_contact = 0
		KEY_COMMA:
			selected_contact = maxi(selected_contact - 1, 0)
		KEY_PERIOD:
			selected_contact += 1
		KEY_R:
			reset_pending = true
		KEY_1:
			_queue_spawn(Vector3(0, 2, 4))
		KEY_2:
			_queue_spawn(Vector3(-0.7, 1.1, -3.0))
		KEY_3:
			_queue_spawn(Vector3(-4, 1.2, 3.0))
		KEY_4:
			_queue_spawn(Vector3(2, 1.2, 2.5))
		KEY_5:
			_queue_spawn(Vector3(5.5, 1.1, -3.2))


func _queue_spawn(at: Vector3) -> void:
	spawn_position = at
	reset_pending = true


func _physics_process(delta: float) -> void:
	if reset_pending:
		player.global_position = spawn_position
		player.velocity = Vector3.ZERO
		trace = {}
		frozen = false
		auto_freeze = false
		selected_step = 0
		selected_contact = 0
		reset_pending = false
		settle_ticks = 2
		return
	if settle_ticks > 0:
		settle_ticks -= 1
		return
	if frozen:
		return
	var direction := Vector3.ZERO
	direction.x = float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT))
	direction.z = float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP))
	direction = direction.normalized()
	player.velocity.x = direction.x * SPEED
	player.velocity.z = direction.z * SPEED
	player.velocity.y -= GRAVITY * delta
	if Input.is_physical_key_pressed(KEY_SPACE) and player.is_on_floor():
		player.velocity.y = 5.5
	player.move_and_slide()
	if available and tracing:
		trace = player.call("get_movement_trace")
		if auto_freeze:
			var steps: Array = trace.get("steps", [])
			for i in range(steps.size()):
				if steps[i].get("wall", false):
					selected_step = i
					frozen = true
					auto_freeze = false
					break
	if player.position.y < -8:
		reset_pending = true


func _process(_delta: float) -> void:
	status.text = "%s  |  tracing %s  |  auto-freeze %s" % ["FROZEN" if frozen else "LIVE", "ON" if tracing else "OFF", "ARMED" if auto_freeze else "OFF"]
	if available:
		_draw_trace()


func _vec(v: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [v.x, v.y, v.z]


func _draw_trace() -> void:
	wire_mesh.clear_surfaces()
	var steps: Array = trace.get("steps", [])
	if steps.is_empty():
		info.text = "No trace. Move with tracing enabled.\n\nMain grounded slide loop only.\nNo snap/platform subquery capture."
		return
	selected_step = clampi(selected_step, 0, steps.size() - 1)
	var step: Dictionary = steps[selected_step]
	var contacts: Array = step["contacts"]
	var reason := str(step["exit_reason"])
	info.text = "Call %s / physics tick %s\nIteration %d of %d | %s\nQuery collided: %s\nActual aggregate: floor=%s wall=%s\nceiling=%s | contacts=%d\n\nRequested (m): %s\nQuery travel (m): %s\nRemainder (m): %s\nMotion after (m): %s\nVelocity after (m/s): %s" % [trace["call"], trace["physics_frame"], selected_step + 1, steps.size(), reason, step["query_collided"], step["floor"], step["wall"], step["ceiling"], contacts.size(), _vec(step["requested_motion"]), _vec(step["travel"]), _vec(step["remainder"]), _vec(step["motion_after"]), _vec(step["velocity_after"])]
	if contacts.is_empty():
		info.text += "\n\nThis iteration has no contacts.\nSelect another iteration with [ / ]."
		return
	selected_contact = clampi(selected_contact, 0, contacts.size() - 1)
	var contact: Dictionary = contacts[selected_contact]
	if not contact["math_valid"]:
		info.text += "\n\nContact math unavailable: zero vector."
		return
	info.text += "\n\nContact %d of %d | angle to up: %.2f°\nNormal: %s\nPink is a geometric comparison,\nnot the solver's final response.\nMain slide loop only; no snap tracing." % [selected_contact + 1, contacts.size(), contact["angle_degrees"], _vec(contact["normal"])]
	var point: Vector3 = contact["position"]
	wire_mesh.surface_begin(Mesh.PRIMITIVE_LINES, wire_material)
	_arrow(point, step["requested_motion"] * MOTION_SCALE, CYAN)
	_arrow(point, step["motion_after"] * MOTION_SCALE, GREEN)
	_arrow(point, contact["normal"].normalized() * 0.8, GOLD)
	_arrow(point, contact["tangent_component"] * MOTION_SCALE, MAGENTA)
	var tangent: Vector3 = contact["plane_tangent"] * 0.35
	var bitangent: Vector3 = contact["plane_bitangent"] * 0.35
	_line(point - tangent, point + tangent, Color.GRAY)
	_line(point - bitangent, point + bitangent, Color.GRAY)
	wire_mesh.surface_end()


func _line(a: Vector3, b: Vector3, color: Color) -> void:
	# Trace vectors/positions are world-space. ImmediateMesh vertices are local.
	wire_mesh.surface_set_color(color)
	wire_mesh.surface_add_vertex(wire_node.to_local(a))
	wire_mesh.surface_set_color(color)
	wire_mesh.surface_add_vertex(wire_node.to_local(b))


func _arrow(origin: Vector3, vector: Vector3, color: Color) -> void:
	if vector.length_squared() < 0.000001:
		return
	var tip := origin + vector
	var direction := vector.normalized()
	var reference := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var side := direction.cross(reference).normalized()
	var head := minf(0.15, vector.length() * 0.3)
	_line(origin, tip, color)
	_line(tip, tip - direction * head + side * head * 0.5, color)
	_line(tip, tip - direction * head - side * head * 0.5, color)
