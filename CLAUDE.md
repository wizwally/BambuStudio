# CLAUDE.md: BambuStudio for iPad (fork `wizwally/BambuStudio`, branch `ipad-core`)

Guidance for Claude Code working in this repository. Everything specific to the
port lives under `ios/`. The rest of the tree is upstream BambuStudio, modified
as little as possible so we can rebase on upstream later.

## Who and how

- Owner: Gualtiero Saderis (Gualti), embedded software engineer: C/C++, Linux, MQTT; first iOS project.
- **Talk to him in Italian.** Write code, comments, commit messages and this file in English.
- Personal project. Distribution through an alternative store is fine; the App Store comes later.
- He often works remotely from an iPad Pro (Tailscale + SSH + tmux, Jump Desktop) while this Mac
  stays at home. Long builds belong in tmux. Never ask for passwords, tokens or the printer access code.
- The Mac disk is nearly full (about 230 GB, a few GB free). Don't create large build trees casually.
  The external SSD is exFAT and must stay exFAT, so don't move the repo there. If space is ever needed,
  an APFS sparsebundle on the SSD is the agreed option. Bitdefender is installed: it once caused
  "Operation not permitted", which is why the repo lives in `~/Development`, not `~/Documents`.

## Goal and decisions so far

1. Pick an open-source slicer that supports Bambu Lab printers and port it to iPad
   (iPad Pro M4 11", 256 GB = 8 GB RAM). **BambuStudio** was chosen over OrcaSlicer to keep
   MakerWorld integration as a later option.
2. License: AGPL-3.0. Keep the fork public; the app must stay AGPL-compliant.
3. Bambu's networking plugin (`bambu_networking`) is closed source and not available on iOS.
   Printer communication is re-implemented in the app (LAN MQTT/FTPS); see the backlog.
4. Gualti's printer: **Bambu Lab P1S, 0.4 nozzle**. Default profile:
   "Bambu Lab P1S 0.4 nozzle" / "0.20mm Standard @BBL X1C" / "Bambu PLA Basic @BBL P1S 0.4 nozzle".
5. Architecture: libslic3r (GUI-free engine) + a thin C++ facade (`ios/core/SlicerCore`) packaged as
   `SlicerCore.xcframework`, an Objective-C++ bridge, and a SwiftUI + Metal app (`ios/app`).
   No wxWidgets and no OpenGL on iPad.

## Repository layout (`ios/`)

| Path | What it is |
| --- | --- |
| `ios/core/SlicerCore.hpp/.cpp` | Facade over libslic3r. `slice()`: presets → `full_config()`, then model → centred on the bed → `Print::apply/validate/process/export_gcode`, optionally collecting toolpaths. `load_mesh()` returns the placed mesh and the bed. `list_presets()` lists printers/processes/filaments compatible with a printer, plus its defaults. `role_name()`. The header includes no libslic3r headers. |
| `ios/core/NetworkStubs.cpp` | No-op `Http` and `BBL_Encrypt`; libslic3r only uses them for encrypted logs. |
| `ios/core/NanoSVG.cpp` | nanosvg implementation (upstream only compiles it in the GUI). |
| `ios/core/main.cpp` | `bbs-core-slice` test CLI (macOS/Linux only): `--list`, `--preview`, `--threads`. |
| `ios/core/CMakeLists.txt` | `slicer_core` and the OBJECT library `slicer_core_gui_shims`, passed via `$<TARGET_OBJECTS>`. |
| `ios/deps/CMakeLists.txt` | iOS superbuild of the dependencies. Reuses upstream `deps/` recipes; GMP/MPFR/OpenSSL are custom. |
| `ios/app/project.yml` | XcodeGen spec (target `SlicerPoC`, bundle id `com.wizwally.slicerpoc`, iPad only, iOS 17). The `.xcodeproj` is generated and git-ignored. |
| `ios/app/Sources/SlicerBridge.h/.mm` | Objective-C facade: `SCSlicer`, `SCSliceResult`, `SCMesh`, `SCToolpaths`, `SCPresetList` (zero-copy `NSData` from `std::vector`). |
| `ios/app/Sources/SlicerPoCApp.swift` | App entry, `SliceModel`, sidebar UI, `-autotest`, `PrinterAutotest` (`-printertest`). |
| `ios/app/Sources/PresetStore.swift` | Printer/process/filament pickers; cached per printer; selection saved in UserDefaults. |
| `ios/app/Sources/Viewport/` | Metal viewport: `Renderer.swift` (bed, lit mesh, instanced toolpath boxes, offscreen `snapshot()`), `Shaders.metal`, `OrbitCamera.swift`, `ViewportView.swift` (MTKView, gestures, layer slider, legend). |
| `ios/app/Sources/Printer/` | LAN printer status: `MQTTClient.swift` (MQTT 3.1.1 over TLS, certificate pinning), `PrinterStatus.swift` (merges P1-style delta reports), `PrinterConnection.swift` (settings, Keychain, reconnect), `PrinterView.swift`. |
| `ios/tools/` | `flatten_profile.py`, `compare_gcode.py`, `make_test_models.py` (writes `cube20.stl` and `sphere_dense.stl`, about 200k triangles, to `ios/test/models/`), `fake_printer.py` (fake P1S over MQTT/TLS on 127.0.0.1:8883, serial `01P00TEST000001`, code `12345678`). |
| `ios/scripts/` | Build pipeline, see below. Logs go to `ios/logs/` (git-ignored). |
| `ios/README.md` | Italian overview for Gualti. |

Upstream files touched (keep this list minimal and documented):

- `CMakeLists.txt`:
  - `option(SLIC3R_CORE_ONLY)`, which forces `SLIC3R_GUI` off and skips CURL/OpenGL/GLEW/glfw;
  - on iOS, defines `SLIC3R_NO_POST_PROCESS_SCRIPTS`.
- `src/CMakeLists.txt`: with `SLIC3R_CORE_ONLY`, adds `ios/core` after libslic3r and returns.
- `src/libslic3r/MeshDiagnostics.hpp`: missing `#include "Point.hpp"`.
- `src/libslic3r/GCode/PostProcessor.cpp`: stub `run_script` under `SLIC3R_NO_POST_PROCESS_SCRIPTS` (no fork/exec on iOS).
- `src/libslic3r/utils.cpp`: `TargetConditionals.h`, no `libproc.h` on iOS, `get_process_name` uses `getprogname()`.

## Build pipeline (run on this Mac)

All scripts must stay executable (see Conventions). Each writes its log to `ios/logs/`.

```bash
# macOS engine + test CLI (comparison with the official app)
ios/scripts/mac_01_deps.sh          # deps for macOS arm64 (done; don't rerun without reason)
ios/scripts/mac_02_core.sh
ios/scripts/mac_03_test.sh          # slices test models, compares with /Applications/BambuStudio.app

# iPadOS
ios/scripts/ios_01_deps.sh                            # device deps (done; slow, don't rerun)
PLATFORM=iphonesimulator ios/scripts/ios_01_deps.sh   # Simulator deps (done)
ios/scripts/ios_02_core.sh -b                         # libslic3r + core, device slice (-b = no reconfigure)
PLATFORM=iphonesimulator ios/scripts/ios_02_core.sh -b
ios/scripts/ios_03_app.sh            # xcodegen + Simulator build + autotest (+ PNGs in ios/logs/autotest/)
ios/scripts/ios_03_app.sh --open     # also leaves the app open in the Simulator
ios/scripts/ios_03_app.sh --printer-test   # app vs ios/tools/fake_printer.py
ios/scripts/ios_04_device.sh --build-only  # device build, unsigned (no iPad needed)
ios/scripts/ios_04_device.sh               # sign (Personal Team E9F29Q4C7F), install, autotest on the iPad
ios/scripts/ios_04_device.sh --no-test     # sign + install only
```

- Rebuild the core with `ios_02_core.sh -b` for **both** platforms whenever `ios/core` or libslic3r changes.
  App-only changes just need `ios_03_app.sh` or `ios_04_device.sh`.
- `ios/build/deps*/dep_*-prefix` and `deps/build/arm64/dep_*-prefix` were deleted to free disk space.
  The installed deps (`.../BambuStudio_deps/usr/local`) are intact. Rerunning a deps script now rebuilds
  everything from scratch, so avoid it unless a dependency really changes.
- `libslic3r_version.h` embeds the build time: reconfiguring CMake recompiles almost everything.
  Prefer `-b` (build without reconfigure).
- Autotest: `-autotest` slices `cube20` and `sphere_dense` on the P1S and `cube20` on the A1 mini, then prints
  `AUTOTEST {json}` lines and renders model and preview PNGs. `-printertest <host> <serial> <code>` exercises the
  printer monitor.
- Device: iPad "iPad_WW" (UDID 00008132-001459190A99801C), Developer Mode on, free Personal Team: the app
  expires after 7 days, so rerun `ios_04_device.sh` to renew. Wireless install works only on the same LAN after
  Xcode's "Connect via network". The Metal Toolchain had to be installed (`xcodebuild -downloadComponent MetalToolchain`).

## Pitfalls already solved (don't reintroduce)

- **TBB deadlock:** `name_tbb_thread_pool_threads_set_locale()` uses a barrier sized on
  `this_task_arena::max_concurrency()`. Limiting threads with `tbb::global_control` deadlocks.
  Use `tbb::task_arena` (`run_limited()` in SlicerCore.cpp).
- **iOS cross-compiling:**
  - `-DCMAKE_SYSTEM_PROCESSOR=arm64` is required;
  - `CMAKE_FIND_ROOT_PATH_MODE_* = ONLY` and `CMAKE_IGNORE_PREFIX_PATH=/opt/homebrew`, otherwise Homebrew libraries (zstd) leak in;
  - autotools: `--build=aarch64-apple-darwin20 --host=aarch64-apple-darwin`; GMP needs `--disable-assembly`;
  - OpenSSL: `ios64-xcrun` / `iossimulator-xcrun`, arch and min-version flags passed via `CFLAGS` (not as Configure args), no `no-apps`;
  - Boost: keep `context` and `coroutine` (asio needs them);
  - CGAL patch: leave `IN_GIT_REPO` unset.
- **Packaging:** `libtool -static` merges every archive. Don't filter on `*d.a`: it drops `libboost_thread.a`
  and `libTKG2d.a`.
- **App bundle:** never put a top-level `resources/` folder in the .app. On a case-insensitive filesystem CFBundle treats
  it as `Resources/` → "Missing bundle ID". Profiles are copied to `BambuResources/profiles/BBL{,.json}`.
- **Simulator install:** ad-hoc signing (`CODE_SIGN_IDENTITY=-`), installed from a `ditto` copy in `$TMPDIR`.
- **`devicectl process launch`:** put `--` before the bundle id, otherwise app arguments like `-autotest` are parsed as devicectl flags.
- **SwiftUI:** ternaries mixing `Color.primary` / `Color.red` need explicit `Color` types.

## Verified results

- Engine vs official BambuStudio CLI (macOS):
  - cube: identical except one 0.001 mm rounding;
  - dense sphere: about 1% more moves, extrusion within 0.04%. First difference is in the G29 bounding box (80 vs 79.9975), likely mesh preprocessing. Not investigated yet.
- Simulator, 10 threads: cube 100 layers, about 1 s total, 14.85 min estimated; sphere 400 layers, about 3–6 s, 82 min, peak RSS about 520–580 MB.
  A1 mini cube centred at (90,90), 18.7 min.
- Sphere G-code size varies slightly between identical runs (1861270 vs 1856438 bytes): nondeterminism, probably threading. Open.
- Real iPad: app installed and running, slices models imported from iCloud. Gualti checked a 3DBenchy G-code
  and it looked right; a physical print test is pending.
- Printer monitor: `fake_printer.py` tested with paho-mqtt (connect, bad code rejected, pushall, deltas).
  The Swift client has **not** been run yet: `ios_03_app.sh --printer-test` is the next thing to run.

## Backlog (in order)

1. **Verify the LAN status monitor** (code committed in `dae83498f`, never built):
   - run `ios_03_app.sh --printer-test` and fix any compile or runtime issue;
   - then on the iPad against the real P1S (`ios_04_device.sh --no-test`, enter IP/serial/access code in the "Stampante" panel; allow Local Network).
   Read the P1S firmware version from the panel: the next step depends on it.
2. **Send and start prints (LAN)**. Prerequisite decided by Gualti: P1S in **LAN-only + Developer Mode**
   (P1 series: firmware ≥ 01.08.02.00). This loses Bambu Handy and cloud printing; firmware updates then go via microSD.
   Ask him before assuming it is enabled. Plan:
   - FTPS upload (implicit TLS, port 990, user `bblp`, access code; requires TLS session reuse on the data channel)
     to the printer's microSD, probably via libcurl built for iOS (OpenSSL for iOS already exists);
   - MQTT `project_file` (for `.gcode.3mf`) or `gcode_file` commands on `device/<serial>/request`;
   - export `.gcode.3mf` (Bambu format, carries plate/print options) from libslic3r `bbs_3mf`;
   - print options UI (bed leveling, timelapse, AMS mapping).
   Without Developer Mode only status reading works (Bambu authorization control, 2025).
3. **Printer discovery:** SSDP on UDP 2021 needs the multicast entitlement (paid Apple account), so for now IP is entered manually.
4. **Plate handling:** move/rotate/scale objects, multiple objects, 3MF with plates, arrange. Extract the GUI-free
   logic from `src/slic3r/GUI/PartPlate.cpp`.
5. **Investigate engine differences:** the sphere G29 bbox difference vs desktop and the run-to-run nondeterminism.
6. **Polish:** thumbnails in results, G-code export naming, memory for big models (toolpaths can be large),
   performance numbers on the real iPad (run `ios_04_device.sh` with autotest).
7. **Distribution:** paid Apple Developer account, then an alternative EU marketplace (e.g. AltStore PAL needs notarization)
   or the App Store. Check the AGPL obligations. MakerWorld integration later (WebView + login; cloud APIs are restricted).

## Conventions

- **Every shell script you create or modify must be executable**: `chmod 755` and `git update-index --chmod=+x`
  (mode 100755 in git). Gualti asked for this explicitly.
- Keep upstream changes minimal and listed above. New code goes under `ios/`.
- Commits: small and descriptive, English. Gualti's git identity is configured on this Mac. Ask before pushing
  if he hasn't said otherwise.
- Prefer verifying with the autotests and logs (`ios/logs/*.log`, `ios/logs/autotest*/`) before declaring something done.
- Keep `ios/README.md` (Italian) in sync when scripts or the layout change, and update the Backlog section of this file
  when a step is done or plans change.
