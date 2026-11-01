# MotionBricks in Godot 4

Real-time generative character animation in Godot 4, driven by
[motion-bricks.cpp](https://github.com/localai-org/motion-bricks.cpp), a C++/GGML port of NVIDIA's
**MotionBricks** (SIGGRAPH 2026). A small GDExtension exposes the model to GDScript, and a demo scene
walks, runs and jumps a 34-joint Unitree G1 skeleton around, planned live on the CPU.

> Status: working proof of concept on macOS (Apple Silicon). Not tested on Windows or Linux.

## Demo

[Watch the demo video](docs/demo.mp4) (50 s: walking, running, jumping and turning, planned live on the CPU).

## What you get

- **`MotionBricksG1`**, a GDExtension class: load the model, load styles, ask for the next chunk of motion.
- **`skeleton_view.tscn`**, the demo: a skeleton you steer with WASD, planned on a worker thread.
- **`bench.tscn`**, a thread-count benchmark.
- Build scripts that go from a fresh clone to a running demo.

## Demo controls

| Key | Action |
| --- | --- |
| W A S D | Walk, relative to the camera |
| Shift (+ W A S D) | Run (the model is asked for a faster target speed; Up/Down changes it, 1.5 to 6 m/s) |
| Space | Jump (standing and running versions, see below) |
| Left / Right | Orbit the camera |
| 1 / 2 | Walk style / zombie walk style |

The HUD shows the last and worst plan time against the 533 ms budget, the number of plans, and the
`last jump`: the distance the root jumped when a new chunk took over (about 0.1 m or less is normal).

## Requirements

- macOS on Apple Silicon, Xcode command line tools (`xcode-select --install`)
- `brew install cmake ninja`
- Godot 4.5 or newer (developed on 4.7)
- About 1 GB of disk for the model weights

## Setup

Run these from the repo root:

```bash
bash scripts/build-motionbricks-mac.sh   # clones and builds motion-bricks.cpp (CPU only), runs its tests
bash scripts/download-weights-mac.sh     # downloads the G1 weights (about 733 MB), checks SHA-256 of every file
bash scripts/build-extension-mac.sh      # builds the GDExtension into bin/
```

Then open the folder in Godot and press **Cmd+B** (the main scene is `skeleton_view.tscn`).
The model takes about 4 s to load; after that you should see the skeleton idling.

If Godot was already open when you built the extension, quit it completely (Cmd+Q) and reopen.
Godot only loads extensions at startup, and macOS keeps the old library in memory until the app quits.

Paths are found automatically (`mb_paths.gd`). To override them, set `MOTIONBRICKS_LIB` (path to
`libmotionbricks.0.1.0.dylib`) and `MOTIONBRICKS_WEIGHTS` (the `generated` folder) before starting Godot.

## How the extension was made

The goal was to call a C++ animation model from Godot without turning Godot into a build of the model.

### 1. Use the library's C ABI, not its C++

motion-bricks.cpp ships a stable C interface (`include/motionbricks/motionbricks.h`, ABI version 1):
opaque handles (`mb_model`, `mb_style`, `mb_agent`, `mb_command`, `mb_motion`), `mb_status` return codes
and error buffers. Everything the extension needs is in that header:

`mb_model_load`, `mb_style_load`, `mb_agent_create / reset / plan / advance`, `mb_command_set_*`,
`mb_motion_get_*`.

### 2. godot-cpp, 4.5 branch

The extension is built with [godot-cpp](https://github.com/godotengine/godot-cpp) (branch `4.5`) and
CMake. The 4.5 branch also loads in newer Godot versions, so the `.gdextension` sets
`compatibility_minimum = "4.5"` and runs on 4.7.

```ini
[configuration]
entry_symbol = "motionbricks_library_init"
compatibility_minimum = "4.5"

[libraries]
macos.debug = "res://bin/libmotionbricks_gd.dylib"
macos.release = "res://bin/libmotionbricks_gd.dylib"
```

### 3. Load the library at runtime (dlopen / dlsym)

The extension does **not** link against libmotionbricks. It includes the header only for types and
signatures and resolves every function with `dlsym` through an X-macro list:

```cpp
#define MB_API_LIST(X) X(mb_abi_version) X(mb_model_load) ... 
struct MotionBricksApi {
#define MB_DECLARE(name) decltype(&::name) name = nullptr;
    MB_API_LIST(MB_DECLARE)
};
```

Why: the extension stays tiny, builds without the model's dependencies (GGML etc.), and the library
can be rebuilt or swapped without touching the extension. `load_library(path)` is called from GDScript.

### 4. Two classes

- `MotionBricksProbe`: smoke test (`load_library`, `get_abi_version`). Used first to prove the whole
  chain (build, load in Godot, call C ABI) before any model code.
- `MotionBricksG1`: the real API, a `RefCounted` registered with `GDREGISTER_CLASS`.

```gdscript
var mb := MotionBricksG1.new()
mb.load_library(lib_path)
mb.load_model(weights + "/g1-f32", 4)          # 4 threads
mb.load_style(weights + "/styles/walk.mbstyle")
mb.reset("idle")
var r := mb.plan("walk", Vector3(0, 0, 1), Vector3(0, 0, 1), -1.0, seed)
# r = { frames, joints, plan_ms, root: PackedVector3Array, rotations: PackedFloat32Array (xyzw) }
mb.advance(16)                                  # move the agent's context forward, then plan again
```

Other getters: `get_joint_names()`, `get_joint_parents()`, `get_neutral_positions()`,
`get_style_names()`, `get_last_error()`.

Details worth knowing:

- Commands (`mb_command`) are created and freed per `plan()` call; styles are kept in a map.
- Free order is styles, agent, model, then `dlclose`.
- CPU only. The model has no Metal backend; speed comes from threads.
- `plan()` returns `{}` on failure; read `get_last_error()`.

### 5. Skeleton and forward kinematics (`g1_fk.gd`)

The model outputs a root translation and local quaternions (x, y, z, w) for 34 joints, Y-up, metres,
30 FPS. Joint offsets are `neutral[child] - neutral[parent]` (the neutral positions come from the model).

```
position[child] = position[parent] + world_rot[parent] * offset[child]
world_rot[child] = world_rot[parent] * local_q[child]
```

The GDScript FK was checked against an independent numpy implementation with random rotations; the
maximum difference was about 3e-7 m.

### 6. Real-time loop (`skeleton_view.gd`)

- A chunk is 44 frames (1.47 s). The playhead advances at 30 FPS.
- When controls change (or every 16 frames while moving), a worker `Thread` calls `advance(floor(playhead))`
  and then `plan(...)`. The main thread never waits for the model.
- When the new chunk arrives, `playhead = max(0, playhead - advance)` keeps the time that passed during planning.
- A new seed is used for every request.
- Movement direction comes from the camera's orbit angle only. (Using the camera position made the direction
  drift while the camera followed the character, which caused endless re-plans that restarted the animation.)
- A new chunk is only requested when the direction changes by more than about 14 degrees.

### 7. Speed: 4 threads, not all cores

Measured with `bench.tscn` on an 8-core Apple Silicon Mac (average per replan):

| Threads | Average | Worst |
| --- | --- | --- |
| 1 | 84 ms | 93 ms |
| 2 | 59 ms | 67 ms |
| **4** | **36 ms** | **38 ms** |
| 6 | 50 ms | 60 ms |
| 8 | 156 ms | 418 ms |
| all cores (0) | 113 ms | 263 ms |

Spreading work across the efficiency cores slows the whole job down. `skeleton_view.gd` uses
`THREADS := 4`. Run `bench.tscn` on your own machine and change the constant if needed.

### 8. Procedural jump

The G1 model has no jump style, so the jump is layered on top of the generated pose in `_jump_pose()`:
crouch, takeoff, tuck, landing, with a pelvis lift that follows a parabola and compensation so the feet
stay on the ground. A standing jump swings and raises the arms; a running jump keeps the arms back,
leans the torso forward and switches the legs to a stride (front knee up, back leg trailing).
All timings and angles are constants at the top of the jump block and in `_jump_pose()`.

## Styles available

`idle`, `walk`, `slow_walk`, `stealth_walk`, `walk_stealth`, `injured_walk`, `walk_scared`,
`walk_zombie`, `walk_happy_dance`, `walk_boxing`, `walk_gun`, `walk_left`, `walk_right`,
`elbow_crawling`, `hand_crawling`. There is no run or jump style; running is a higher target speed on `walk`.

## Limitations

- The C++ port supports only the **Unitree G1** skeleton, not NVIDIA's human (SOMA) model. To animate a human
  character, the G1 motion must be retargeted (for example to a Mixamo rig); that is not done yet.
- The demo draws joints and bones. There is no character mesh.
- CPU only, macOS only so far.
- Weights can still be a first-plan spike (about 140 ms) right after loading.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `Identifier "MotionBricksG1" not declared` | The extension is not loaded: rebuild it, then quit Godot with Cmd+Q and reopen |
| Grey window, nothing moves | A different scene is running; open `skeleton_view.tscn` and press Cmd+B. Also remove any breakpoints |
| F6 does nothing | On a Mac laptop, use Cmd+R (current scene) or Cmd+B (project) |
| Python `CERTIFICATE_VERIFY_FAILED` when downloading weights | The script already sets the macOS certificate bundle and falls back to curl |
| Plans are slow | Run `bench.tscn` and set `THREADS` to the fastest value |

## Layout

```
extension/      GDExtension source (C++, CMake)
scripts/        build and download scripts (macOS)
skeleton_view.* demo scene and script
g1_fk.gd        forward kinematics
mb_paths.gd     locates the library and weights
bench.*         thread benchmark
probe_test.gd   console test of the full API
third_party/    motion-bricks.cpp, cloned by the scripts (not committed)
bin/            built extension (not committed)
```

## Licenses and credits

- MotionBricks: NVIDIA. Model weights are under the **NVIDIA Open Model License**; they are not included in this
  repo and are downloaded from Hugging Face (`LocalAI-io/MotionBricks-G1-GGML`) by the script.
- motion-bricks.cpp: see its own repository and license.
- godot-cpp and Godot: MIT.
- The code in this repository: **MIT** (see `LICENSE`). Anyone may fork, reuse, modify and improve it. The model weights and motion-bricks.cpp keep their own licenses.
