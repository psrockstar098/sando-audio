# SANDO Audio — Phase 3 STATUS

Phase 3 (Intelligence & Conversational AI): **COMPLETE and
builder-verified**, 2026-11-15. Built and tested on this VM
(Intel Xeon Platinum 8321HC, 4 cores, AVX-512, Ubuntu 24.04, glibc 2.39,
Zig 0.17.1). Local commits only until pushed — origin/main is still the
Phase 2 head until D verifies independently and pushes.

## Phase 3 verification summary (builder; D's independent verification pending)

| Check | Result |
|---|---|
| `zig build -j1 -Dcpu=baseline` | clean, exit 0 |
| `zig build test -j1 -Dcpu=baseline`, test binary run directly | **91/91 tests pass** (was 68/68), exit 0, **no leaks** |
| CLI smoke (`version`, `doctor`) | 0.3.0 Phase 3; doctor correct (audio.cpp 0.9.3, 17 tasks, 133 families) |
| Live `converse` (Moonshine-Streaming-small, 287 MB, CPU; mock brain) | **PROVEN with real speech**: "Hello, this is Sando speaking." → transcribed exactly, mock brain answered "Hello! I am Sando. Speak to me and I will answer." (~9.5 s for the whole turn, model load included) |
| Live barge-in (`converse --interrupt`) | **PROVEN**: reply cut short at "Hello!", interrupt transcribed live ("Tell me a joke instead."), follow-up joke delivered, 1 barge-in, 4 history turns |
| Live multi-turn + cache | 2 turns, history grows to 4; repeat of the same audio reports `asr=cached` (SmartCache leg proven live) |
| Live `--brain http` (local mock HTTP brain on 127.0.0.1:18080) | **PROVEN**: OpenAI-compatible SSE reply streamed through the real `std.http` transport; unconsumed interrupt ran as a final turn, as designed |
| TTS (Qwen3-TTS-0.6B-Q8_0, 1.9 GB) | **Still not runnable on this VM** — the new size guard refuses the load honestly: "tts skipped: model qwen3-tts-0.6b is 1898 MB but only ~577–1094 MB is free — this machine cannot load it" (free RAM varies run to run) |
| C API conversation entry points | present: `sando_conversation_create_mock`, `sando_conversation_create_agent`, `sando_conversation_ask`, `sando_conversation_history_count`, `sando_conversation_destroy` (22 exports total) |
| Weights in git | none — `models/` (2.3 GB) and `voices/` are gitignored; tree clean |
| audio.cpp version shipped | **0.9.3 prebuilt, NOT 0.9.5** — the 0.9.5 source build remains an open follow-up (see Phase 2 section) and was NOT attempted in Phase 3 |

## Phase 3 modules (what landed)

- BrainLink (`src/brain.zig`): `Brain` vtable (streaming chunks +
  cancel), `MockBrain` (scripted replies), `AgentBrain` (in-process
  host callback), `HttpBrain` (OpenAI-compatible chat completions over
  `std.http`, SSE parser, pluggable transport). **No Authorization
  header is ever sent** — the HTTP brain only talks to a local or
  otherwise unauthenticated endpoint. No keys, no real cloud calls.
- Conversation orchestration (`src/conversation.zig`): `Session`
  (bounded history, oldest evicted first, in-memory only),
  `SentenceChunker` (incremental, 200-char runs), `Conversation`
  (listen → transcribe → think → speak → listen, SmartCache on both
  legs, ReflexEngine turn-end gating, barge-in mid-reply with
  partial-reply + follow-up in history).
- CLI `converse` (`src/cli.zig`): repeatable `--wav`, `--interrupt`,
  `--brain mock|http`, `--brain-url`, `--brain-model`, `--voice`,
  `--language`, `--cache`, `--out-dir` (default `converse-out`,
  `turn<N>-sent<M>.wav`). VAD segments each file (energy fallback,
  labelled); segments group into turns on silence gaps via the
  turn-end probability. TTS model size guard from `/proc/meminfo`.
- C API conversation entry points (`src/c_api.zig`): mock + agent
  (host C callback, `callconv(.c)`, reply copied by the library).
- Version bump 0.2.0 → 0.3.0 (`src/root.zig`, `src/c_api.zig`, CLI
  usage).

## Phase 3 honest gaps

1. **TTS leg not verified live** (unchanged) — the guard proves the
   load is refused, but no TTS audio has ever been produced on this
   VM. Needs a machine with room for the 2 GB model (Dominic's
   laptop) and a real enrolled voice.
2. **No real cloud brain has been called** — the HTTP brain was proven
   only against a local mock server. A real provider needs a key and
   is Dominic's call, not this phase's.
3. **No live mic/speaker** (unchanged from Phase 1) — WAV + null
   device only.
4. **No silero-vad weights on disk** — VAD works via the honest energy
   fallback.
5. **No WASM build** (unchanged).
6. **audio.cpp 0.9.5 not landed** (see Phase 2 section).
7. **Abbreviation heuristic**: the sentence splitter cuts "Dr." early
   (documented in code) — acceptable for speech, not for prose.

---

# SANDO Audio — Phase 2 STATUS (kept below for the record)

Phase 2 (Real-Time Speech & Voice Intelligence): **COMPLETE and verified
by D from a clean worktree**, 2026-11-15. Built and tested on this VM
(Intel Xeon Platinum 8321HC, 4 cores, AVX-512, Ubuntu 24.04, glibc 2.39,
Zig 0.17.1). Local commits only until pushed — origin/main is still the
Phase 1 head until D pushes.

## Phase 2 verification summary (D, independent, fresh worktree)

| Check | Result |
|---|---|
| `zig build -j1 -Dcpu=baseline` (clean cache, fresh worktree) | clean, exit 0 |
| `zig build test -j1 -Dcpu=baseline`, test binary run directly | **68/68 tests pass** (was 42/42), exit 0 |
| CLI smoke (`version`, `doctor`, `config validate`, `bench`) | 0.2.0 Phase 2; doctor correct (Vulkan unavailable — no DRI node, the Phase 2 fix); bench memory ~584 ns/iter, inference honestly skipped |
| Live ASR (Moonshine-Streaming-small, 287 MB, CPU) | **PROVEN with real speech**: "Hello, this is Sando speaking." → "Hello, this is sandos speaking." (~4 s on this VM) |
| `stream` / `vad` / `voices` commands | behave honestly: stream on a tone gives empty final, 0 segments; vad finds the tone segment via energy fallback (no silero model on disk); `voices list` reports no profiles |
| TTS (Qwen3-TTS-0.6B-Q8_0, 1.9 GB) | **NOT runnable on this VM**: `run --task tts` fails with `error: Runtime` (2 GB model vs ~1.4 GB free RAM; no voice profile enrolled either — `voices/` is empty) |
| C API inference entry points | present: `sando_engine_infer_text`, `sando_engine_infer_tts`, `sando_stream_create/push/finish` (17 exports total) |
| Weights in git | none — `models/` (2.3 GB) and `voices/` are gitignored; tree clean |
| audio.cpp version shipped | **0.9.3 prebuilt, NOT 0.9.5** — see below |

## audio.cpp latest — NOT landed in Phase 2

Dominic ordered audio.cpp latest (0.9.5) during Phase 2. What happened:
the source was cloned to `~/workspace/tmp/audio.cpp-src`, but **no source
build was ever configured** (no `build/` dir, no CMakeCache) and the
vendored libs in `third-party/audiocpp` are still the 0.9.3 prebuilt
(timestamps 03:11, Phase 1). The bindings were extended for the new
surface but the linked library did not change — `doctor` still reports
build 0.9.3. The 0.9.5 prebuilt cannot load here (needs glibc 2.43, VM
has 2.39); a minimal source build was never attempted. This is an open
follow-up, not a Phase 2 claim.

## Phase 2 modules (what landed)

- LiveStream Engine + VAD (`src/streaming.zig`, `src/vad.zig`): streaming
  ASR over WAV, partial transcripts, VAD activity, barge-in counting.
- AudioSense (`src/audiosense.zig`): capability-first interface.
- VoiceDNA (`src/voicedna.zig`): voice profiles with a hard consent
  rule — no real person's voice is used in tests; only synthetic
  enrollment exists (`voices enroll-synthetic`).
- SmartCache (`src/cache.zig`): voice/language/context-aware TTS + ASR
  cache (64 MiB, in-process).
- ReflexEngine (`src/reflex.zig`): speculative scheduling, turn-end
  probability, fastest-viable model choice.
- Lazy per-task loading + plugin manifests (`src/runtime.zig`,
  `src/plugin.zig`): a missing TTS file no longer blocks an ASR run.
- C API inference entry points (`src/c_api.zig`).
- CLI: `stream`, `vad`, `voices list/enroll-synthetic/delete`,
  `run --cache`, `plugins load --manifest`.
- Hardware fix: Vulkan "available" now requires a DRI render node, not
  just the loader — this VM ships libvulkan.so.1 with no GPU, and auto
  selection used to hand audio.cpp a dead Vulkan backend (found by the
  Moonshine ASR smoke test; new test asserts the invariant).

## Phase 2 honest gaps

1. **TTS not verified live** (see above) — needs a machine with room
   for the 2 GB model (Dominic's laptop) and a real enrolled voice.
2. **Whisper-small substitution**: the brief's Whisper-small-Q8_0 does
   not exist as a standalone GGUF in the audio.cpp hub, so
   Moonshine-Streaming-small substitutes for ASR. Documented in the
   example config and README.
3. **No live mic/speaker** (unchanged from Phase 1) — WAV + null
   device only.
4. **No silero-vad weights on disk** — VAD works via the honest energy
   fallback; the ONNX file was not fetched.
5. **No WASM build** (unchanged).
6. **audio.cpp 0.9.5 not landed** (see above).

---

# SANDO Audio — Phase 1 STATUS (kept below for the record)

Phase 1 (Core Engine & Universal Runtime): **COMPLETE and verified**,
2026-11-15. Built and tested on this VM (Intel Xeon Platinum 8321HC,
4 cores, AVX-512, Ubuntu 24.04, glibc 2.39, Zig 0.17.1).

## Verification summary

| Check | Result |
|---|---|
| `zig build -j1 -Dcpu=baseline` | clean |
| `zig build test -j1 -Dcpu=baseline` | **42/42 tests pass, no leaks** |
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
| 13 | Test suite + docs | ✅ Done | 42/42 tests, no leaks; README, STATUS (this file), `docs/API.md`; example config + plugin manifest |

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
