# SANDO Audio — Phase 1: Core Engine & Universal Runtime

A real-time African voice intelligence engine, engineered in Zig,
Liberia-first (Liberian English + Koloqua P0). This repository is the
Zig orchestration/runtime layer over [audio.cpp](https://github.com/0xShug0/audio.cpp)
via its public C ABI.

Phase 1 is the foundation: the engine starts, detects real hardware,
loads real models through audio.cpp, and runs offline and streaming
inference. Nothing is faked — when a backend or a model is missing, the
engine says so instead of simulating success.

## Status

Phase 1 is complete and verified on this machine. See [STATUS.md](STATUS.md)
for the per-item checklist with exact verification results.

- Zig 0.17.1, `-Dcpu=baseline` (portable binaries)
- audio.cpp 0.9.3 prebuilt (ABI 0.2.0), 17 tasks, 133 model families
- 40 unit tests, all passing, no leaks
- Library `libsando.a` + CLI `sando-audio` + C API + sample plugin

## Build

```sh
zig build -j1 -Dcpu=baseline            # null backend (no audio.cpp)
zig build -j1 -Dcpu=baseline -Daudiocpp-dir=third-party/audiocpp
zig build test -j1 -Dcpu=baseline       # unit tests
```

The build auto-detects `third-party/audiocpp` (include/ + lib/) when it
exists. The prebuilt is NOT committed — see `.gitignore`. The version in
use is recorded in [STATUS.md](STATUS.md).

> Prebuilt compatibility: audio.cpp 0.9.4/0.9.5 require glibc 2.43 and do
> NOT load on Ubuntu 24.04 (glibc 2.39). The vendored 0.9.3 prebuilt
> loads (max glibc 2.38). The bindings target ABI 0.2.0, which is also
> present in ABI 0.3.0 (0.9.5 only adds `audiocpp_log_set`).

## Configure

```sh
cp config/sando.example.toml config/sando.toml
sando-audio config validate config/sando.toml
sando-audio doctor
```

Place GGUF/ONNX weights in `models/` and list them in the config.
The engine never downloads weights.

## Use

```sh
sando-audio version
sando-audio doctor
sando-audio models list
sando-audio run --task tts --text "Hello, this is Sando." --out out.wav
sando-audio run --task asr --wav in.wav
sando-audio run --task asr --wav in.wav --mode streaming
sando-audio bench --iterations 100
sando-audio bench --model qwen3-tts-0.6b --task tts --iterations 10
sando-audio plugins list
sando-audio plugins load zig-out/lib/libsando-plugin-noop.so
```

## Layout

```
src/
  root.zig      library root
  main.zig      CLI entry point
  hardware.zig  CPU detection + backend probes/selection
  memory.zig    frame pool, lock-free ring, bump arena
  config.zig    strict TOML config (validated, reloadable)
  audiocpp.zig  audio.cpp C ABI bindings (ABI 0.2.0)
  runtime.zig   sessions, requests, responses, streaming, latency
  models.zig    model registry (ModelHub + SmartCache, LRU)
  plugin.zig    .so plugin loader (sando_plugin descriptor ABI)
  engine.zig    the Engine: owns everything, start/stop/reload
  audio.zig     WAV file I/O + null device (offline mode)
  c_api.zig     C API for embedding
  cli.zig       command-line interface
  doctor.zig    never-fails system report
  bench.zig     memory-path + inference benchmarks
config/         sando.example.toml
examples/       plugins/noop — sample passthrough plugin
docs/           API.md — library, C API, plugin ABI, config schema
```

## Design rules

- **Real data only.** No fake backends, no simulated inference. A
  missing library, device, or model is an error with a reason.
- **Zero-copy audio path.** Frames are preallocated, moved by pointer
  through lock-free rings. Nothing in the audio path allocates.
- **Prebuilt first.** audio.cpp is used as a prebuilt binary; a full
  source build OOMs on small machines and is not attempted.
- **Config is strict.** Unknown sections and keys are errors, so
  `config validate` catches typos instead of ignoring them.
- **Reload is conservative.** Changing mode, sample rate, channels, or
  the model list requires a restart; backend and flag changes reload
  live. The engine refuses to dangle pointers instead of guessing.

## What Phase 1 does NOT do (honest gaps)

- No model weights ship with the repo; inference is unverified until
  real GGUF/ONNX files are present (see STATUS.md).
- No live microphone/speaker capture — WAV files (offline) and the null
  device only. Real device I/O is Phase 2.
- No WASM build verified — no emcc/emsdk on the build machine.
- C API covers lifecycle, introspection, and model loading; inference
  entry points land in Phase 2.
- The plugin manifest format is documented but not yet read by the
  loader (the .so descriptor is authoritative).

## License

MIT — see [LICENSE](LICENSE).
