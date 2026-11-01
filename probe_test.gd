extends Node

# Where the downloaded weights live (see download-weights-mac.sh).
const MbPaths := preload("res://mb_paths.gd")
var WEIGHTS := MbPaths.weights_dir()
# Library built by build-motionbricks-mac.sh
var lib_path := MbPaths.library_path()

func _ready() -> void:
	var mb := MotionBricksG1.new()
	if not mb.load_library(lib_path):
		print("FAILED load_library: ", mb.get_last_error())
		return
	print("library loaded, ABI version ", mb.get_abi_version())

	var t0 := Time.get_ticks_msec()
	if not mb.load_model(WEIGHTS + "/g1-f32", 0):
		print("FAILED load_model: ", mb.get_last_error())
		return
	print("model loaded in ", Time.get_ticks_msec() - t0, " ms, joints = ", mb.get_joint_count())
	print("joint names: ", mb.get_joint_names())
	print("joint parents: ", mb.get_joint_parents())

	for style in ["idle", "walk", "walk_zombie"]:
		var loaded := mb.load_style(WEIGHTS + "/styles/" + style + ".mbstyle")
		if loaded.is_empty():
			print("FAILED load_style ", style, ": ", mb.get_last_error())
			return
	print("styles loaded: ", mb.get_style_names())

	if not mb.reset("idle"):
		print("FAILED reset: ", mb.get_last_error())
		return
	var forward := Vector3(0, 0, 1)
	var result := mb.plan("walk", forward, forward, -1.0, 1)
	if result.is_empty():
		print("FAILED plan: ", mb.get_last_error())
		return
	var root: PackedVector3Array = result["root"]
	var rot: PackedFloat32Array = result["rotations"]
	print("plan 1: frames=", result["frames"], " joints=", result["joints"], " time=", snappedf(result["plan_ms"], 0.1), " ms")
	print("root first frame: ", root[0], "  last frame: ", root[root.size() - 1])
	print("first joint rotation (x,y,z,w) frame 0: ", rot.slice(0, 4))

	# Replan like the reference demo does: advance 16 frames, then plan again.
	var total := 0.0
	var worst := 0.0
	for i in 10:
		if not mb.advance(16):
			print("FAILED advance: ", mb.get_last_error())
			return
		var again := mb.plan("walk", forward, forward, -1.0, 2 + i)
		if again.is_empty():
			print("FAILED replan: ", mb.get_last_error())
			return
		total += again["plan_ms"]
		worst = maxf(worst, again["plan_ms"])
	print("10 replans: average ", snappedf(total / 10.0, 0.1), " ms, worst ", snappedf(worst, 0.1), " ms")
	print("(each plan covers about ", result["frames"], " frames = ", snappedf(float(result["frames"]) / 30.0, 0.01), " s of animation)")
