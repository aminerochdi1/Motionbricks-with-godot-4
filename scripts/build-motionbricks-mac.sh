#!/usr/bin/env bash
# Builds motion-bricks.cpp (CPU only, no model download) on macOS and checks the C ABI.
# Run from the repo root:  bash scripts/build-motionbricks-mac.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/motion-bricks.cpp"
MB_COMMIT=60a5f4c0b5eef3d893d4a8c253cc3fc68924c559   # version this project was developed against
BUILD="$HOME/motionbricks-build"   # internal disk: the ORICO drive may not support symlinks

xcode-select -p >/dev/null 2>&1 || { echo "Run: xcode-select --install"; exit 1; }
for t in cmake ninja git python3; do
  command -v "$t" >/dev/null || { echo "Missing $t. Run: brew install cmake ninja"; exit 1; }
done

if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$ROOT/third_party"
  git clone https://github.com/localai-org/motion-bricks.cpp.git "$SRC"
fi
git -C "$SRC" checkout -q "$MB_COMMIT"

cd "$SRC"
# The repo's pinned GGML commit does not exist upstream; use v0.20.2 from the repo's own notes.
if [ -z "$(ls -A ggml 2>/dev/null)" ]; then rm -rf ggml; git clone https://github.com/ggml-org/ggml.git ggml; fi
git -C ggml checkout -q 8c63e70982c95ceb862e3a1073a2c1beef75d60a

cmake -S . -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DMOTIONBRICKS_DOWNLOAD_MODELS=OFF -DMOTIONBRICKS_ENABLE_VULKAN=OFF -DMOTIONBRICKS_CPU_ALL_VARIANTS=OFF
cmake --build "$BUILD" -j"$(sysctl -n hw.ncpu)"
ctest --test-dir "$BUILD" -E purego --output-on-failure

LIB="$(find "$BUILD" -maxdepth 1 -name 'libmotionbricks*.dylib' | head -1)"
echo "Library: $LIB"
python3 -I - "$LIB" <<'PY'
import ctypes, sys
lib = ctypes.CDLL(sys.argv[1])
lib.mb_abi_version.restype = ctypes.c_uint32
print("mb_abi_version ->", lib.mb_abi_version())
PY
echo "OK: motion-bricks.cpp builds and loads on this Mac."
