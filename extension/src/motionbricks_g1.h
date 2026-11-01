#pragma once

#include <map>
#include <string>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>

// Only used for types and signatures: every function is resolved at runtime with dlsym,
// so this extension does not link against libmotionbricks.
#include <motionbricks/motionbricks.h>

#define MB_API_LIST(X) \
	X(mb_abi_version) \
	X(mb_status_string) \
	X(mb_runtime_options_create) \
	X(mb_runtime_options_free) \
	X(mb_runtime_options_set_device) \
	X(mb_runtime_options_set_threads) \
	X(mb_command_create) \
	X(mb_command_free) \
	X(mb_command_set_style) \
	X(mb_command_set_movement_direction) \
	X(mb_command_set_facing_direction) \
	X(mb_command_set_target_speed) \
	X(mb_command_set_seed) \
	X(mb_model_load) \
	X(mb_model_free) \
	X(mb_model_get_joint_count) \
	X(mb_model_get_joint_name) \
	X(mb_model_get_joint_parent) \
	X(mb_model_get_neutral_joint_position) \
	X(mb_style_load) \
	X(mb_style_free) \
	X(mb_style_get_name) \
	X(mb_agent_create) \
	X(mb_agent_free) \
	X(mb_agent_reset) \
	X(mb_agent_plan) \
	X(mb_agent_advance) \
	X(mb_motion_free) \
	X(mb_motion_get_frame_count) \
	X(mb_motion_get_joint_count) \
	X(mb_motion_get_root_translations) \
	X(mb_motion_get_local_rotations_xyzw)

namespace godot {

struct MotionBricksApi {
#define MB_DECLARE(name) decltype(&::name) name = nullptr;
	MB_API_LIST(MB_DECLARE)
#undef MB_DECLARE
};

// MotionBricks G1 animation planner for GDScript (CPU only).
//
//   var mb := MotionBricksG1.new()
//   mb.load_library(".../libmotionbricks.0.1.0.dylib")
//   mb.load_model(".../generated/g1-f32")
//   mb.load_style(".../generated/styles/walk.mbstyle")
//   mb.reset("walk")
//   var result := mb.plan("walk", Vector3(0, 0, 1), Vector3(0, 0, 1), -1.0, 1)
class MotionBricksG1 : public RefCounted {
	GDCLASS(MotionBricksG1, RefCounted)

	void *lib = nullptr;
	MotionBricksApi api;
	mb_model *model = nullptr;
	mb_agent *agent = nullptr;
	std::map<std::string, mb_style *> styles;

	PackedStringArray joint_names;
	PackedInt32Array joint_parents;
	PackedVector3Array neutral_positions;

	char error_buf[1024] = { 0 };
	String last_error;

	char *err_buf();
	bool check(mb_status p_status, const char *p_what);
	void fail(const String &p_message);
	void free_model();

protected:
	static void _bind_methods();

public:
	MotionBricksG1() = default;
	~MotionBricksG1();

	bool load_library(const String &p_path);
	void unload();
	int get_abi_version() const;

	bool load_model(const String &p_bundle_directory, int p_threads = 0);
	int get_joint_count() const;
	PackedStringArray get_joint_names() const;
	PackedInt32Array get_joint_parents() const;
	PackedVector3Array get_neutral_positions() const;

	String load_style(const String &p_path);
	PackedStringArray get_style_names() const;

	bool reset(const String &p_style);
	// Returns {} on failure (see get_last_error()). On success:
	//   frames: int, joints: int, plan_ms: float,
	//   root: PackedVector3Array (frames),
	//   rotations: PackedFloat32Array (frames * joints * 4, local quaternions as x, y, z, w)
	Dictionary plan(const String &p_style, const Vector3 &p_move, const Vector3 &p_facing, double p_speed, int64_t p_seed);
	bool advance(int p_frames);

	String get_last_error() const;
};

} // namespace godot
