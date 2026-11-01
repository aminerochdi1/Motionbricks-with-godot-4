extends RefCounted
# Finds the MotionBricks library and model weights without hardcoded machine paths.
# Override with the environment variables MOTIONBRICKS_LIB and MOTIONBRICKS_WEIGHTS.

static func library_path() -> String:
	var env := OS.get_environment("MOTIONBRICKS_LIB")
	if not env.is_empty():
		return env
	return OS.get_environment("HOME") + "/motionbricks-build/libmotionbricks.0.1.0.dylib"


static func weights_dir() -> String:
	var env := OS.get_environment("MOTIONBRICKS_WEIGHTS")
	if not env.is_empty():
		return env
	var project := ProjectSettings.globalize_path("res://").simplify_path()
	var candidates := [
		project.path_join("third_party/motion-bricks.cpp/generated"),
		project.path_join("../../motion-bricks.cpp/generated").simplify_path(), # layout of the original author's machine
	]
	for c in candidates:
		if DirAccess.dir_exists_absolute(c.path_join("g1-f32")):
			return c
	return candidates[0]
