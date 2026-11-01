#include "motionbricks_probe.h"

#include <dlfcn.h> // macOS / Linux only for now

#include <cstdint>

#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

typedef uint32_t (*mb_abi_version_fn)();

void MotionBricksProbe::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_library", "path"), &MotionBricksProbe::load_library);
	ClassDB::bind_method(D_METHOD("unload"), &MotionBricksProbe::unload);
	ClassDB::bind_method(D_METHOD("is_loaded"), &MotionBricksProbe::is_loaded);
	ClassDB::bind_method(D_METHOD("get_abi_version"), &MotionBricksProbe::get_abi_version);
}

MotionBricksProbe::~MotionBricksProbe() {
	unload();
}

bool MotionBricksProbe::load_library(const String &p_path) {
	unload();
	handle = dlopen(p_path.utf8().get_data(), RTLD_NOW | RTLD_LOCAL);
	if (!handle) {
		const char *err = dlerror();
		UtilityFunctions::push_error(String("MotionBricksProbe: dlopen failed: ") + String(err ? err : "unknown error"));
		return false;
	}
	return true;
}

void MotionBricksProbe::unload() {
	if (handle) {
		dlclose(handle);
		handle = nullptr;
	}
}

bool MotionBricksProbe::is_loaded() const {
	return handle != nullptr;
}

int MotionBricksProbe::get_abi_version() const {
	if (!handle) {
		return -1;
	}
	mb_abi_version_fn fn = reinterpret_cast<mb_abi_version_fn>(dlsym(handle, "mb_abi_version"));
	if (!fn) {
		return -2;
	}
	return static_cast<int>(fn());
}
