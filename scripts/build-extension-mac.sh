#!/usr/bin/env bash
# Builds the MotionBricks Godot extension (GDExtension) for macOS and drops it in bin/.
# Run from the repo root:  bash scripts/build-extension-mac.sh
# Needs build-motionbricks-mac.sh to have been run first (it builds the library this loads).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/extension"
PROJECT="$ROOT"
GODOTCPP="$HOME/godot-cpp-4.5"          # internal disk: the ORICO drive may not support symlinks
BUILD="$HOME/motionbricks-gd-build"

for t in cmake ninja git python3; do
  command -v "$t" >/dev/null || { echo "Missing $t. Run: brew install cmake ninja"; exit 1; }
done

if [ ! -f "$GODOTCPP/CMakeLists.txt" ]; then
  git clone --depth 1 -b 4.5 https://github.com/godotengine/godot-cpp.git "$GODOTCPP"
fi

mkdir -p "$PROJECT/bin"
cmake -S "$EXT" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Debug \
  -DGODOTCPP_DIR="$GODOTCPP" -DMB_GD_OUTPUT_DIR="$PROJECT/bin" \
  -DMB_INCLUDE_DIR="$ROOT/third_party/motion-bricks.cpp/include"
cmake --build "$BUILD" -j"$(sysctl -n hw.ncpu)"

codesign --force --sign - "$PROJECT/bin/libmotionbricks_gd.dylib" 2>/dev/null || true
ls -l "$PROJECT/bin"

[ -f "$HOME/motionbricks-build/libmotionbricks.0.1.0.dylib" ] || \
  echo "WARNING: $HOME/motionbricks-build/libmotionbricks.0.1.0.dylib not found. Run build-motionbricks-mac.sh first."
echo "OK. In Godot: open the project, open skeleton_view.tscn and press Cmd+B."
