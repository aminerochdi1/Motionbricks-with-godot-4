#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// Smoke-test class: loads libmotionbricks at runtime (dlopen) and calls its C ABI.
class MotionBricksProbe : public RefCounted {
	GDCLASS(MotionBricksProbe, RefCounted)

	void *handle = nullptr;

protected:
	static void _bind_methods();

public:
	MotionBricksProbe() = default;
	~MotionBricksProbe();

	bool load_library(const String &p_path);
	void unload();
	bool is_loaded() const;
	// Returns mb_abi_version(), -1 if no library is loaded, -2 if the symbol is missing.
	int get_abi_version() const;
};

} // namespace godot
