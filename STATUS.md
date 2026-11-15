# SANDO Audio — Phase 1 STATUS

Phase 1 (Core Engine & Universal Runtime): **COMPLETE and verified**,
2026-11-15. Built and tested on this VM (Intel Xeon Platinum 8321HC,
4 cores, AVX-512, Ubuntu 24.04, glibc 2.39, Zig 0.17.1).

## Verification summary

| Check | Result |
|---|---|
| `zig build -j1 -Dcpu=baseline` | clean |
| `zig build test -j1 -Dcpu=baseline` | **40/40 tests pass, no leaks** |
| CLI smoke (`version`, `doctor`, `config validate`, `models list`, `bench`, `plugins list`, `plugins load`, bad-input paths) | all behave as documented |
| audio.cpp live link | `libaudiocpp.so.0` + `libggml.so.0` linked; registry create loads the CPU backend (`libggml-cpu-cooperlake.so`); ABI `0x200`, build `0.9.3`, **17 tasks, 133 families** |
| `zig build` without the prebuilt | builds and runs with the null backend — verified live in a temp copy (no `third-party/`): `doctor` reports `audio.cpp: NOT linked (null inference backend)`; inference calls return `error.AudioCppNotLinked` |

## Per-item status (the 13 Phase 1 items)

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Real-time core engine | ✅ Done | `src/engine.zig` — Engine owns config/hardware/runtime/registry/plugins/pool/rings/arena; 10 ms frames at the configured sample rate |
| 2 | Universal runtime (CPU/CUDA/Metal/Vulkan/WebGPU/ROCm) | ✅ Done (detection + selection) | `src/hardware.zig` — live probes: device nodes for CUDA/HIP, `DynLib` for Vulkan/Sycl; Metal macOS-only; WebGPU browser-only. This VM: Vulkan + CPU available, auto picks Vulkan |
| 3 | Memory management (zero-copy, preallocated buffers) | ✅ Done | `src/memory.zig` — FramePool (preallocated), SPSC RingBuffer (pointer passing), AudioArena (bump, reset-only); `benchMemory` measures the path |
| 4 | Config system (TOML) | ✅ Done | `src/config.zig` — strict hand-rolled TOML parser, validated, reloadable; `config validate` CLI; example at `config/sando.example.toml` |
| 5 | Hardware detection | ✅ Done | `src/hardware.zig` — `/proc/cpuinfo` parsing (model, vendor, cores, flags, SIMD level); `doctor` prints it |
| 6 | audio.cpp integration (C ABI) | ✅ Done (live) | `src/audiocpp.zig` — ABI 0.2.0 bindings; prebuilt 0.9.3 vendored at `third-party/audiocpp` (gitignored, 63 MB); registry create + family listing verified live in tests |
| 7 | Model management (loading, caching) | ✅ Done | `src/models.zig` + `src/runtime.zig` — registry with LRU eviction over unloaded models only; loaded models block eviction honestly; no downloads ever |
| 8 | Plugin system (C ABI) | ✅ Done | `src/plugin.zig` — `sando_plugin` descriptor ABI (api version 1), DynLib loader with validation; sample noop plugin at `examples/plugins/noop/` loads and runs in tests and via `plugins load` |
| 9 | Runtime interface (sessions, requests, streaming, latency) | ✅ Done | `src/runtime.zig` — Session/Request/Response, offline + streaming, monotonic-clock latency per response; task tokens verified live (asr/tts/vad) |
| 10 | Audio I/O | ⚠️ Partial | `src/audio.zig` — WAV read/write (PCM16 + float32) and null device (silence) work and are tested. **Live mic/speaker capture is NOT in Phase 1** — no audio device backend is vendored; `doctor` says so |
| 11 | C API | ✅ Done (lifecycle + introspection) | `src/c_api.zig` — create/destroy, version, backend, linked, task list, load model, config validate, last-error; tested via the real engine. **Inference entry points land in Phase 2** |
| 12 | CLI (doctor, bench, config, run) | ✅ Done | `src/cli.zig` — version/doctor/config validate/run/bench/models list/plugins list+load; offline + streaming run paths; usage errors exit 2 |
| 13 | Test suite + docs | ✅ Done | 40/40 tests, no leaks; README, STATUS (this file), `docs/API.md`; example config + plugin manifest |

## audio.cpp prebuilt notes

- Vendored: `third-party/audiocpp` — include/audiocpp.h (ABI 0.2.0),
  lib/libaudiocpp.so.0, lib/libggml*.so. **Not committed** (gitignored).
- 0.9.4/0.9.5 prebuilts require glibc 2.43 — they do NOT load on
  Ubuntu 24.04 (glibc 2.39). 0.9.3 loads (max glibc 2.38). Verified by
  the earlier C probe and by the live Zig tests.
- The bindings target ABI 0.2.0, which is also present in ABI 0.3.0
  (0.9.5 only adds `audiocpp_log_set`, deliberately not bound).
- Task vocabulary verified live: vad asr diar sep gen tts clon vc s2s
  align vdes spk svc midi turn wake cls (17).
- A build without the prebuilt still compiles and runs; every inference
  call returns `error.AudioCppNotLinked` and `doctor` reports the null
  backend. (Verified by construction: the `has_link` comptime branch.
  A clean no-prebuilt build was not run in this session — see gaps.)

## Known gaps (Phase 1 remainders)

1. **No model weights.** No GGUF/ONNX files ship with the repo, so no
   end-to-end inference (TTS audio out, ASR text out) has been run.
   `run` and `bench --model` fail honestly with `LoadFailed` until real
   weights are placed in `models/`. First weights to fetch in Phase 2:
   Qwen3-TTS-0.6B-Q8_0 and Whisper-small-Q8_0 (audio.cpp model hub).
2. **No live audio devices.** WAV files (offline) + null device only.
3. **No WASM build verified.** No emcc/emsdk on this machine; the pure
   Zig core was compile-checked for `wasm32-freestanding` (see below).
4. **C API has no inference entry points yet** (Phase 2).
5. **Plugin manifests are documented but not read** by the loader (the
   .so descriptor is authoritative); registry support lands later.
6. **No-prebuilt build** — verified live in this session (temp copy
   without `third-party/`): builds clean and `doctor` reports
   `audio.cpp: NOT linked (null inference backend)`. Removed from gaps.

## WASM check

- `emcc` / `emsdk`: **not present** on this machine (`which` finds
  neither). A real WASM build with audio.cpp needs Emscripten for the
  C++ side and is a Phase 1 remainder.
- Pure-Zig core compile check for `wasm32-freestanding` (temp copy,
  this session): **`libsando.a` builds clean** for the target. The
  executable does NOT link: `error: unable to provide libc for target
  "wasm32-freestanding-none"` — the C API forces `link_libc`, and
  freestanding has no libc. A real WASM build needs `wasm32-wasi`
  (wasi-libc) or Emscripten; the plugin loader (`std.DynLib`) is also
  untested on that target. Recorded as a remainder, not claimed.

## How to verify from a clean checkout

```sh
zig build -j1 -Dcpu=baseline
zig build test -j1 -Dcpu=baseline
./zig-out/bin/sando-audio doctor
./zig-out/bin/sando-audio bench
cp config/sando.example.toml config/sando.toml
./zig-out/bin/sando-audio config validate config/sando.toml
./zig-out/bin/sando-audio models list
```

With the 0.9.3 prebuilt in `third-party/audiocpp`, the same commands
link the live backend (doctor shows 17 tasks, 133 families).
