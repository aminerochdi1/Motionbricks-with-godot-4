#include "motionbricks_g1.h"

#include <dlfcn.h> // macOS / Linux only for now

#include <chrono>
#include <cstdint>
#include <cstring>

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void MotionBricksG1::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_library", "path"), &MotionBricksG1::load_library);
	ClassDB::bind_method(D_METHOD("unload"), &MotionBricksG1::unload);
	ClassDB::bind_method(D_METHOD("get_abi_version"), &MotionBricksG1::get_abi_version);

	ClassDB::bind_method(D_METHOD("load_model", "bundle_directory", "threads"), &MotionBricksG1::load_model, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_joint_count"), &MotionBricksG1::get_joint_count);
	ClassDB::bind_method(D_METHOD("get_joint_names"), &MotionBricksG1::get_joint_names);
	ClassDB::bind_method(D_METHOD("get_joint_parents"), &MotionBricksG1::get_joint_parents);
	ClassDB::bind_method(D_METHOD("get_neutral_positions"), &MotionBricksG1::get_neutral_positions);

	ClassDB::bind_method(D_METHOD("load_style", "path"), &MotionBricksG1::load_style);
	ClassDB::bind_method(D_METHOD("get_style_names"), &MotionBricksG1::get_style_names);

	ClassDB::bind_method(D_METHOD("reset", "style"), &MotionBricksG1::reset);
	ClassDB::bind_method(D_METHOD("plan", "style", "move", "facing", "speed", "seed"), &MotionBricksG1::plan);
	ClassDB::bind_method(D_METHOD("advance", "frames"), &MotionBricksG1::advance);

	ClassDB::bind_method(D_METHOD("get_last_error"), &MotionBricksG1::get_last_error);
}

MotionBricksG1::~MotionBricksG1() {
	unload();
}

char *MotionBricksG1::err_buf() {
	error_buf[0] = '\0';
	return error_buf;
}

void MotionBricksG1::fail(const String &p_message) {
	last_error = p_message;
	UtilityFunctions::push_error(String("MotionBricksG1: ") + p_message);
}

bool MotionBricksG1::check(mb_status p_status, const char *p_what) {
	if (p_status == MB_OK) {
		return true;
	}
	const char *name = api.mb_status_string ? api.mb_status_string(p_status) : "error";
	fail(String(p_what) + ": " + String(name ? name : "error") + " - " + String(error_buf));
	return false;
}

bool MotionBricksG1::load_library(const String &p_path) {
	unload();
	last_error = String();

	lib = dlopen(p_path.utf8().get_data(), RTLD_NOW | RTLD_LOCAL);
	if (!lib) {
		const char *err = dlerror();
		fail(String("dlopen failed: ") + String(err ? err : "unknown error"));
		return false;
	}

	String missing;
#define MB_RESOLVE(name) \
	api.name = reinterpret_cast<decltype(api.name)>(dlsym(lib, #name)); \
	if (!api.name) { \
		missing += String(" ") + String(#name); \
	}
	MB_API_LIST(MB_RESOLVE)
#undef MB_RESOLVE

	if (!missing.is_empty()) {
		fail(String("library is missing functions:") + missing);
		unload();
		return false;
	}
	if (api.mb_abi_version() != 1) {
		fail(String("unsupported ABI version ") + String::num_int64(api.mb_abi_version()) + " (expected 1)");
		unload();
		return false;
	}
	return true;
}

void MotionBricksG1::free_model() {
	for (auto &entry : styles) {
		if (entry.second && api.mb_style_free) {
			api.mb_style_free(entry.second);
		}
	}
	styles.clear();
	if (agent && api.mb_agent_free) {
		api.mb_agent_free(agent);
	}
	agent = nullptr;
	if (model && api.mb_model_free) {
		api.mb_model_free(model);
	}
	model = nullptr;
	joint_names.clear();
	joint_parents.clear();
	neutral_positions.clear();
}

void MotionBricksG1::unload() {
	free_model();
	if (lib) {
		dlclose(lib);
		lib = nullptr;
	}
	api = MotionBricksApi();
}

int MotionBricksG1::get_abi_version() const {
	if (!lib || !api.mb_abi_version) {
		return -1;
	}
	return static_cast<int>(api.mb_abi_version());
}

bool MotionBricksG1::load_model(const String &p_bundle_directory, int p_threads) {
	if (!lib) {
		fail("load_library() has not succeeded yet");
		return false;
	}
	free_model();
	last_error = String();

	mb_runtime_options *options = nullptr;
	if (!check(api.mb_runtime_options_create(&options, err_buf(), sizeof(error_buf)), "runtime_options_create")) {
		return false;
	}
	const uint32_t threads = p_threads > 0 ? static_cast<uint32_t>(p_threads) : 0U; // 0 = all cores
	bool ok = check(api.mb_runtime_options_set_device(options, MB_DEVICE_CPU, err_buf(), sizeof(error_buf)), "set_device") &&
			check(api.mb_runtime_options_set_threads(options, threads, err_buf(), sizeof(error_buf)), "set_threads");
	if (ok) {
		const CharString dir = p_bundle_directory.utf8();
		ok = check(api.mb_model_load(dir.get_data(), options, &model, err_buf(), sizeof(error_buf)), "model_load");
	}
	api.mb_runtime_options_free(options);
	if (!ok) {
		model = nullptr;
		return false;
	}

	if (!check(api.mb_agent_create(model, &agent, err_buf(), sizeof(error_buf)), "agent_create")) {
		free_model();
		return false;
	}

	uint32_t count = 0;
	if (!check(api.mb_model_get_joint_count(model, &count, err_buf(), sizeof(error_buf)), "get_joint_count")) {
		free_model();
		return false;
	}
	for (uint32_t j = 0; j < count; j++) {
		const char *name = nullptr;
		int32_t parent = -1;
		float x = 0, y = 0, z = 0;
		if (!check(api.mb_model_get_joint_name(model, j, &name, err_buf(), sizeof(error_buf)), "get_joint_name") ||
				!check(api.mb_model_get_joint_parent(model, j, &parent, err_buf(), sizeof(error_buf)), "get_joint_parent") ||
				!check(api.mb_model_get_neutral_joint_position(model, j, &x, &y, &z, err_buf(), sizeof(error_buf)), "get_neutral_joint_position")) {
			free_model();
			return false;
		}
		joint_names.push_back(String(name ? name : ""));
		joint_parents.push_back(parent);
		neutral_positions.push_back(Vector3(x, y, z));
	}
	return true;
}

int MotionBricksG1::get_joint_count() const {
	return static_cast<int>(joint_names.size());
}

PackedStringArray MotionBricksG1::get_joint_names() const {
	return joint_names;
}

PackedInt32Array MotionBricksG1::get_joint_parents() const {
	return joint_parents;
}

PackedVector3Array MotionBricksG1::get_neutral_positions() const {
	return neutral_positions;
}

String MotionBricksG1::load_style(const String &p_path) {
	if (!model) {
		fail("load_model() has not succeeded yet");
		return String();
	}
	mb_style *style = nullptr;
	const CharString path = p_path.utf8();
	if (!check(api.mb_style_load(model, path.get_data(), &style, err_buf(), sizeof(error_buf)), "style_load")) {
		return String();
	}
	const char *name = nullptr;
	if (!check(api.mb_style_get_name(style, &name, err_buf(), sizeof(error_buf)), "style_get_name") || !name) {
		api.mb_style_free(style);
		return String();
	}
	const std::string key(name);
	auto existing = styles.find(key);
	if (existing != styles.end()) {
		api.mb_style_free(existing->second);
		existing->second = style;
	} else {
		styles[key] = style;
	}
	return String(name);
}

PackedStringArray MotionBricksG1::get_style_names() const {
	PackedStringArray names;
	for (const auto &entry : styles) {
		names.push_back(String(entry.first.c_str()));
	}
	return names;
}

bool MotionBricksG1::reset(const String &p_style) {
	if (!agent) {
		fail("load_model() has not succeeded yet");
		return false;
	}
	auto it = styles.find(std::string(p_style.utf8().get_data()));
	if (it == styles.end()) {
		fail(String("unknown style: ") + p_style);
		return false;
	}
	return check(api.mb_agent_reset(agent, it->second, err_buf(), sizeof(error_buf)), "agent_reset");
}

bool MotionBricksG1::advance(int p_frames) {
	if (!agent) {
		fail("load_model() has not succeeded yet");
		return false;
	}
	if (p_frames < 0) {
		fail("frames must not be negative");
		return false;
	}
	return check(api.mb_agent_advance(agent, static_cast<uint32_t>(p_frames), err_buf(), sizeof(error_buf)), "agent_advance");
}

Dictionary MotionBricksG1::plan(const String &p_style, const Vector3 &p_move, const Vector3 &p_facing, double p_speed, int64_t p_seed) {
	Dictionary out;
	if (!agent) {
		fail("load_model() has not succeeded yet");
		return out;
	}
	auto it = styles.find(std::string(p_style.utf8().get_data()));
	if (it == styles.end()) {
		fail(String("unknown style: ") + p_style);
		return out;
	}

	mb_command *command = nullptr;
	if (!check(api.mb_command_create(&command, err_buf(), sizeof(error_buf)), "command_create")) {
		return out;
	}
	bool ok = check(api.mb_command_set_style(command, it->second, err_buf(), sizeof(error_buf)), "command_set_style") &&
			check(api.mb_command_set_movement_direction(command, p_move.x, p_move.y, p_move.z, err_buf(), sizeof(error_buf)), "command_set_movement_direction") &&
			check(api.mb_command_set_facing_direction(command, p_facing.x, p_facing.y, p_facing.z, err_buf(), sizeof(error_buf)), "command_set_facing_direction") &&
			check(api.mb_command_set_target_speed(command, static_cast<float>(p_speed), err_buf(), sizeof(error_buf)), "command_set_target_speed") &&
			check(api.mb_command_set_seed(command, static_cast<uint64_t>(p_seed), err_buf(), sizeof(error_buf)), "command_set_seed");

	mb_motion *motion = nullptr;
	double plan_ms = 0.0;
	if (ok) {
		const auto t0 = std::chrono::steady_clock::now();
		ok = check(api.mb_agent_plan(agent, command, &motion, err_buf(), sizeof(error_buf)), "agent_plan");
		plan_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
	}
	api.mb_command_free(command);
	if (!ok) {
		return out;
	}

	uint64_t frames = 0, joints = 0, root_values = 0, rot_values = 0;
	const float *root = nullptr;
	const float *rot = nullptr;
	ok = check(api.mb_motion_get_frame_count(motion, &frames, err_buf(), sizeof(error_buf)), "motion_get_frame_count") &&
			check(api.mb_motion_get_joint_count(motion, &joints, err_buf(), sizeof(error_buf)), "motion_get_joint_count") &&
			check(api.mb_motion_get_root_translations(motion, &root, &root_values, err_buf(), sizeof(error_buf)), "motion_get_root_translations") &&
			check(api.mb_motion_get_local_rotations_xyzw(motion, &rot, &rot_values, err_buf(), sizeof(error_buf)), "motion_get_local_rotations_xyzw");
	if (ok && (root_values != frames * 3 || rot_values != frames * joints * 4 || !root || !rot)) {
		fail("motion buffers have unexpected sizes");
		ok = false;
	}
	if (ok) {
		PackedVector3Array root_out;
		root_out.resize(static_cast<int64_t>(frames));
		Vector3 *rw = root_out.ptrw();
		for (uint64_t f = 0; f < frames; f++) {
			rw[f] = Vector3(root[f * 3 + 0], root[f * 3 + 1], root[f * 3 + 2]);
		}
		PackedFloat32Array rot_out;
		rot_out.resize(static_cast<int64_t>(rot_values));
		if (rot_values > 0) {
			std::memcpy(rot_out.ptrw(), rot, rot_values * sizeof(float));
		}
		out["frames"] = static_cast<int64_t>(frames);
		out["joints"] = static_cast<int64_t>(joints);
		out["plan_ms"] = plan_ms;
		out["root"] = root_out;
		out["rotations"] = rot_out;
	}
	api.mb_motion_free(motion);
	return out;
}

String MotionBricksG1::get_last_error() const {
	return last_error;
}
