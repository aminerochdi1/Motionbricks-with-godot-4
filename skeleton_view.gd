extends Node3D
# Walks the MotionBricks G1 skeleton around.
#   W / A / S / D   move (relative to the camera)
#   Left / Right    orbit the camera
#   1 / 2           walk style / zombie walk style
# Planning runs on a worker thread, so the window keeps its frame rate while the model thinks.

const G1Fk := preload("res://g1_fk.gd")

#Temporary Storage Path
const MbPaths := preload("res://mb_paths.gd")
var WEIGHTS := MbPaths.weights_dir()
const FPS := 30.0
const REPLAN_AFTER_FRAMES := 16 # same cadence as the reference demo (about 0.53 s)
const THREADS := 4 # fastest on this Mac (4 performance cores); 0 = all cores was ~7x slower
const JOINT_DIAMETER := 0.05
const ROOT_DIAMETER := 0.09
const BONE_DIAMETER := 0.025
const CAMERA_DISTANCE := 3.4

const GRID_SHADER := """
shader_type spatial;
render_mode unshaded;
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 g = abs(fract(wpos.xz - 0.5) - 0.5) / fwidth(wpos.xz);
	float line = 1.0 - min(min(g.x, g.y), 1.0);
	ALBEDO = mix(vec3(0.15, 0.16, 0.19), vec3(0.42, 0.47, 0.54), line);
}
"""

var lib_path := MbPaths.library_path()

var mb := MotionBricksG1.new()
var ready_ok := false
var error_text := ""

var parents := PackedInt32Array()
var offsets := PackedVector3Array()
var joint_count := 0

# Current animation chunk
var chunk_root := PackedVector3Array()
var chunk_rot := PackedFloat32Array()
var chunk_frames := 0
var playhead := 0.0

# Planning
var worker: Thread = null
var plan_seed := 1
var last_plan_ms := 0.0
var last_drawn_root := Vector3.ZERO
var last_jump := 0.0
var worst_plan_ms := 0.0
var plan_count := 0
var planned_style := ""
var planned_speed := -1.0
const JUMP_HEIGHT := 0.6 # metres
const T_CROUCH := 0.25 # seconds: knees bend before takeoff (shorter when running)
const T_AIR := 0.45 # seconds in the air
const T_LAND := 0.25 # seconds: absorb the landing
const CROUCH_ANGLE := 0.85 # radians of hip flexion at the deepest crouch
const THIGH_SHIN := 0.6 # thigh + shin length, used to lower the pelvis when the knees bend
var jump_clock := -1.0 # < 0 means on the ground
var jump_run := 0.0 # 0 = jump in place, 0.6 = walking jump, 1 = running jump
var jump_lead := 1.0 # which leg leads in a running jump; alternates each jump
var jd_crouch := T_CROUCH
var jd_air := T_AIR
var jd_land := T_LAND
var run_speed := 3.5 # metres per second while Shift is held; Up/Down changes it
var planned_move := Vector3.ZERO
var move_style := "walk"
var facing := Vector3(0, 0, 1)

# Scene objects
var joint_nodes: Array[MeshInstance3D] = []
var bone_nodes: Array[MeshInstance3D] = []
var camera: Camera3D
var floor_mesh: MeshInstance3D
var hud: Label
var cam_yaw := PI - 0.45
var cam_target := Vector3(0, 0.8, 0)


func _ready() -> void:
	_build_world()
	hud.text = "Loading the MotionBricks model (a few seconds)..."
	await get_tree().process_frame
	await get_tree().process_frame
	if not _load_motionbricks():
		hud.text = "Setup failed:\n" + error_text
		return
	_build_skeleton()
	ready_ok = true


func _exit_tree() -> void:
	if worker != null:
		worker.wait_to_finish()
		worker = null


func _load_motionbricks() -> bool:
	if not mb.load_library(lib_path):
		error_text = mb.get_last_error()
		return false
	if not mb.load_model(WEIGHTS + "/g1-f32", THREADS):
		error_text = mb.get_last_error()
		return false
	for style in ["idle", "walk", "walk_zombie"]:
		if mb.load_style(WEIGHTS + "/styles/" + style + ".mbstyle").is_empty():
			error_text = mb.get_last_error()
			return false
	if not mb.reset("idle"):
		error_text = mb.get_last_error()
		return false
	parents = mb.get_joint_parents()
	joint_count = mb.get_joint_count()
	offsets = G1Fk.make_offsets(mb.get_neutral_positions(), parents)
	var first := mb.plan("idle", Vector3.ZERO, facing, -1.0, plan_seed)
	plan_seed += 1
	if first.is_empty():
		error_text = mb.get_last_error()
		return false
	_use_chunk(first, 0)
	planned_style = "idle"
	return true


func _use_chunk(result: Dictionary, advance: int) -> void:
	chunk_root = result["root"]
	chunk_rot = result["rotations"]
	chunk_frames = result["frames"]
	# Frame 0 of the new chunk is the context at `advance`; keep the time that passed while planning.
	playhead = clampf(playhead - advance, 0.0, float(chunk_frames - 1))
	var shown := clampi(int(floor(playhead)), 0, chunk_frames - 1)
	last_jump = chunk_root[shown].distance_to(last_drawn_root)
	last_plan_ms = result["plan_ms"]
	worst_plan_ms = maxf(worst_plan_ms, last_plan_ms)
	plan_count += 1


func _build_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.08, 0.09, 0.11)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.75, 0.8, 0.9)
	environment.ambient_light_energy = 0.7
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 1.0
	add_child(sun)

	camera = Camera3D.new()
	camera.fov = 60.0
	add_child(camera)
	camera.make_current()

	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	var shader := Shader.new()
	shader.code = GRID_SHADER
	var floor_material := ShaderMaterial.new()
	floor_material.shader = shader
	floor_mesh = MeshInstance3D.new()
	floor_mesh.mesh = plane
	floor_mesh.material_override = floor_material
	add_child(floor_mesh)

	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(14, 10)
	hud.add_theme_font_size_override("font_size", 16)
	hud.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)
	_place_camera(0.0)


func _build_skeleton() -> void:
	var names := mb.get_joint_names()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 16
	sphere.rings = 8
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.5
	cylinder.bottom_radius = 0.5
	cylinder.height = 1.0
	cylinder.radial_segments = 10
	cylinder.rings = 1
	for j in joint_count:
		var color := Color(0.86, 0.88, 0.92)
		if names[j].begins_with("left"):
			color = Color(0.35, 0.65, 1.0)
		elif names[j].begins_with("right"):
			color = Color(1.0, 0.62, 0.25)
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.5
		var joint := MeshInstance3D.new()
		joint.mesh = sphere
		joint.material_override = material
		joint.scale = Vector3.ONE * (ROOT_DIAMETER if j == 0 else JOINT_DIAMETER)
		add_child(joint)
		joint_nodes.append(joint)
		if parents[j] >= 0:
			var bone := MeshInstance3D.new()
			bone.mesh = cylinder
			bone.material_override = material
			add_child(bone)
			bone_nodes.append(bone)


# Direction the player wants to move in world space (zero if no key is held).
func _read_input() -> Vector3:
	# Depends only on the orbit angle, so it stays constant while the camera follows the skeleton.
	var forward := Vector3(-sin(cam_yaw), 0.0, -cos(cam_yaw))
	var right := forward.cross(Vector3.UP)
	var move := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		move += forward
	if Input.is_physical_key_pressed(KEY_S):
		move -= forward
	if Input.is_physical_key_pressed(KEY_D):
		move += right
	if Input.is_physical_key_pressed(KEY_A):
		move -= right
	if move.length() > 0.01:
		return move.normalized()
	return Vector3.ZERO


func _process(delta: float) -> void:
	if not ready_ok:
		return

	# 1. Pick up a finished plan.
	if worker != null and not worker.is_alive():
		var result: Dictionary = worker.wait_to_finish()
		worker = null
		if result.is_empty():
			error_text = mb.get_last_error()
		else:
			_use_chunk(result, int(result["advance"]))

	# 2. Input.
	if Input.is_physical_key_pressed(KEY_LEFT):
		cam_yaw += delta * 1.6
	if Input.is_physical_key_pressed(KEY_RIGHT):
		cam_yaw -= delta * 1.6
	if Input.is_physical_key_pressed(KEY_1):
		move_style = "walk"
	if Input.is_physical_key_pressed(KEY_2):
		move_style = "walk_zombie"
	if Input.is_physical_key_pressed(KEY_UP):
		run_speed = minf(run_speed + delta * 1.5, 6.0)
	if Input.is_physical_key_pressed(KEY_DOWN):
		run_speed = maxf(run_speed - delta * 1.5, 1.5)
	var speed := run_speed if Input.is_physical_key_pressed(KEY_SHIFT) else -1.0
	var move := _read_input()
	var moving := move != Vector3.ZERO
	var style := move_style if moving else "idle"
	if moving:
		facing = move

	if jump_clock < 0.0 and Input.is_physical_key_pressed(KEY_SPACE):
		jump_clock = 0.0
		jump_run = 0.0
		if moving:
			jump_run = 1.0 if speed > 0.0 else 0.6
		jump_lead = -jump_lead
		jd_crouch = T_CROUCH * lerpf(1.0, 0.5, jump_run)
		jd_air = T_AIR + 0.12 * jump_run
		jd_land = T_LAND
	if jump_clock >= 0.0:
		jump_clock += delta
		if jump_clock >= jd_crouch + jd_air + jd_land:
			jump_clock = -1.0

	# 3. Playback.
	playhead = minf(playhead + delta * FPS, float(chunk_frames - 1))

	# 4. Ask for a new chunk when the controls change, or every 16 frames while moving.
	if worker == null:
		var direction_changed := move.distance_to(planned_move) > 0.25 # about 14 degrees
		var controls_changed := style != planned_style or direction_changed or not is_equal_approx(speed, planned_speed)
		var cadence_due := moving and playhead >= REPLAN_AFTER_FRAMES
		if controls_changed or cadence_due:
			_request_plan(style, move, speed)

	# 5. Draw.
	var frame := clampi(int(floor(playhead)), 0, chunk_frames - 1)
	_draw_pose(frame)
	_place_camera(delta)
	_update_hud(style, moving)


func _request_plan(style: String, move: Vector3, speed: float) -> void:
	planned_speed = speed
	planned_style = style
	planned_move = move
	var request := {
		"advance": int(floor(playhead)),
		"style": style,
		"move": move,
		"facing": facing,
		"seed": plan_seed,
		"speed": speed,
	}
	plan_seed += 1
	worker = Thread.new()
	worker.start(_plan_job.bind(request))


# Runs on the worker thread. Nothing else touches `mb` while it runs.
func _plan_job(request: Dictionary) -> Dictionary:
	if int(request["advance"]) > 0:
		mb.advance(int(request["advance"]))
	var result := mb.plan(request["style"], request["move"], request["facing"], float(request["speed"]), int(request["seed"]))
	if not result.is_empty():
		result["advance"] = request["advance"]
	return result


static func _rx(angle: float) -> Quaternion:
	return Quaternion(Vector3.RIGHT, angle)


# Extra joint rotations for the current jump time.
# Sign conventions (legs and arms hang along -Y, body faces +Z, rotation about X):
#   hips / shoulders: negative = forward, positive = backward;  knees: positive = shin back;
#   waist: positive = lean forward.
func _jump_pose() -> Dictionary:
	var out := {"lift": 0.0, "adds": {}, "blends": {}}
	if jump_clock < 0.0:
		return out
	var r := jump_run
	var t := jump_clock
	var bend := 0.0
	var height := 0.0
	var arm_idle := 0.0 # standing jump: swing back, then throw both arms up
	var arm_run := 0.0 # running jump: arms stay back
	var lean := 0.0
	var leap := 0.0 # weight of the running-leap leg pose
	var crouch_depth := CROUCH_ANGLE * lerpf(1.0, 0.4, r)
	var lean_ground := lerpf(0.15, 0.25, r)
	var lean_air := lerpf(0.05, 0.35, r)
	if t < jd_crouch:
		var k := smoothstep(0.0, 1.0, t / jd_crouch)
		bend = crouch_depth * k
		arm_idle = 0.9 * k
		arm_run = 0.5 * k
		lean = lean_ground * k
	elif t < jd_crouch + jd_air:
		var u := (t - jd_crouch) / jd_air
		height = 4.0 * JUMP_HEIGHT * lerpf(1.0, 0.8, r) * u * (1.0 - u)
		bend = lerpf(crouch_depth, 0.5, smoothstep(0.0, 0.3, u))
		bend = lerpf(bend, 0.7, smoothstep(0.6, 1.0, u))
		arm_idle = lerpf(0.9, -1.9, smoothstep(0.0, 0.3, u))
		arm_idle = lerpf(arm_idle, -1.2, smoothstep(0.5, 1.0, u))
		arm_run = lerpf(0.5, 0.9, smoothstep(0.0, 0.3, u))
		lean = lerpf(lean_ground, lean_air, smoothstep(0.0, 0.3, u))
		leap = r * smoothstep(0.0, 0.15, u) * (1.0 - smoothstep(0.75, 1.0, u))
	else:
		var k := 1.0 - smoothstep(0.0, 1.0, (t - jd_crouch - jd_air) / jd_land)
		bend = 0.7 * k
		arm_idle = -1.2 * k
		arm_run = 0.9 * k
		lean = lean_air * k
	var arm := lerpf(arm_idle, arm_run, r)
	var adds: Dictionary = out["adds"]
	for hip in [1, 8]:
		adds[hip] = _rx(-bend)
	for knee in [4, 11]:
		adds[knee] = _rx(2.0 * bend)
	for ankle in [5, 12]:
		adds[ankle] = _rx(-bend)
	adds[17] = _rx(lean) # waist pitch
	for shoulder in [18, 26]:
		adds[shoulder] = _rx(arm)
	for elbow in [21, 29]:
		adds[elbow] = _rx(-0.45 * r) # elbows bend a little more when running
	if leap > 0.0:
		# Front leg driven forward with the knee up, back leg trailing.
		var front := [1, 4, 5] if jump_lead > 0.0 else [8, 11, 12]
		var back := [8, 11, 12] if jump_lead > 0.0 else [1, 4, 5]
		var blends: Dictionary = out["blends"]
		blends[front[0]] = [_rx(-1.1), leap]
		blends[front[1]] = [_rx(1.5), leap]
		blends[front[2]] = [_rx(0.2), leap]
		blends[back[0]] = [_rx(0.45), leap]
		blends[back[1]] = [_rx(1.3), leap]
		blends[back[2]] = [_rx(0.3), leap]
	# Lower the pelvis as the knees bend so the feet stay on the ground.
	out["lift"] = height - THIGH_SHIN * (1.0 - cos(bend * (1.0 - leap)))
	return out


func _draw_pose(frame: int) -> void:
	last_drawn_root = chunk_root[frame]
	var jump := _jump_pose()
	var positions := G1Fk.pose(chunk_root[frame] + Vector3(0, float(jump["lift"]), 0), chunk_rot, frame, parents, offsets, jump["adds"], jump["blends"])
	for j in joint_count:
		joint_nodes[j].position = positions[j]
	var bone_index := 0
	for j in joint_count:
		if parents[j] < 0:
			continue
		var a := positions[parents[j]]
		var b := positions[j]
		var d := b - a
		var bone_length := d.length()
		var bone := bone_nodes[bone_index]
		bone_index += 1
		if bone_length < 0.0001:
			bone.visible = false
			continue
		bone.visible = true
		var bone_basis := Basis(Quaternion(Vector3.UP, d / bone_length)) * Basis.from_scale(Vector3(BONE_DIAMETER, bone_length, BONE_DIAMETER))
		bone.transform = Transform3D(bone_basis, (a + b) * 0.5)


func _place_camera(delta: float) -> void:
	if chunk_frames > 0:
		var frame := clampi(int(floor(playhead)), 0, chunk_frames - 1)
		var root := chunk_root[frame]
		var wanted := Vector3(root.x, 0.8, root.z)
		cam_target = cam_target.lerp(wanted, 1.0 - exp(-8.0 * delta))
	var offset := Vector3(sin(cam_yaw) * CAMERA_DISTANCE, 1.3, cos(cam_yaw) * CAMERA_DISTANCE)
	camera.look_at_from_position(cam_target + offset, cam_target + Vector3(0, 0.1, 0), Vector3.UP)
	floor_mesh.position = Vector3(cam_target.x, 0.0, cam_target.z)


func _update_hud(style: String, moving: bool) -> void:
	var text := "MotionBricks G1 on CPU    style: %s%s\n" % [style, "" if moving else " (hold W/A/S/D to walk)"]
	text += "plan time: last %.0f ms, worst %.0f ms   (budget %.0f ms)   plans: %d%s   last jump: %.2f m\n" % [last_plan_ms, worst_plan_ms, REPLAN_AFTER_FRAMES / FPS * 1000.0, plan_count, "   [planning...]" if worker != null else "", last_jump]
	text += "render: %d fps    W/A/S/D move, Left/Right orbit, Space jump, 1 walk, 2 zombie, Shift run (Up/Down speed %.1f m/s)" % [Engine.get_frames_per_second(), run_speed]
	if not error_text.is_empty():
		text += "\nERROR: " + error_text
	hud.text = text
