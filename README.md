# SANDO Audio — Phase 3: Intelligence & Conversational AI

A real-time African voice intelligence engine, engineered in Zig,
Liberia-first (Liberian English + Koloqua P0). This repository is the
Zig orchestration/runtime layer over [audio.cpp](https://github.com/0xShug0/audio.cpp)
via its public C ABI.

Phase 3 is the conversation layer: BrainLink (mock, in-process agent,
and OpenAI-compatible HTTP brains), streaming brain replies, incremental
TTS generation, speech-to-brain-to-speech over the Phase 2 LiveStream
Engine, conversation orchestration with bounded history, intelligent
turn-taking, and interruption-aware barge-in (VoiceContinuum). Nothing
is faked — when a backend or a model is missing, the engine says so
instead of simulating success.

## Status

Phase 3 is complete and builder-verified on this machine (D's
independent verification pending before push). See
[STATUS.md](STATUS.md) for the per-item checklist with exact
verification results.

- Zig 0.17.1, `-Dcpu=baseline` (portable binaries)
- audio.cpp 0.9.3 prebuilt (ABI 0.2.0), 17 tasks, 133 model families
  (0.9.5 was ordered but did not land in Phase 2 — see STATUS.md)
- 91 unit tests, all passing, no leaks
- Live `converse` verified with Moonshine-Streaming-small (287 MB):
  real speech → exact transcript → mock brain reply; barge-in proven
  live (reply cut short, interrupt transcribed, follow-up delivered);
  multi-turn history and the SmartCache ASR leg proven live; the HTTP
  brain proven live against a local mock server (no keys, no cloud)
- TTS is still not runnable on this VM: the new size guard refuses the
  1.9 GB model load honestly ("only ~577–1094 MB is free")
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
sando-audio run --task asr --wav in.wav --cache        # TTS/ASR result cache
sando-audio run --task tts --text "Hello" --voice smoke-voice-01
sando-audio stream --wav in.wav                        # LiveStream Engine: partials + VAD
sando-audio vad --wav in.wav                           # model VAD, else labelled energy fallback
sando-audio converse --wav turn.wav                    # speech-to-brain-to-speech, mock brain
sando-audio converse --wav turn.wav --interrupt cut.wav  # barge-in: interrupt mid-reply
sando-audio converse --wav a.wav --wav b.wav --cache   # multi-turn, SmartCache on both legs
sando-audio converse --wav turn.wav --brain http --brain-url http://127.0.0.1:11434/v1/chat/completions
                                                       # OpenAI-compatible brain, local only, no key
sando-audio voices list
sando-audio voices enroll-synthetic my-voice "My Voice"   # synthetic reference audio only
sando-audio voices delete my-voice
sando-audio bench --iterations 100
sando-audio bench --model qwen3-tts-0.6b --task tts --iterations 10
sando-audio plugins list
sando-audio plugins load zig-out/lib/libsando-plugin-noop.so
sando-audio plugins load --manifest examples/plugins/noop/manifest.toml
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
  c_api.zig     C API for embedding (lifecycle, introspection, inference)
  cli.zig       command-line interface
  doctor.zig    never-fails system report
  bench.zig     memory-path + inference benchmarks
  streaming.zig LiveStream Engine: turn machine, StreamPump, barge-in
  vad.zig       VAD state machine + labelled energy fallback detector
  audiosense.zig capability-first audio separation/diarization/VAD
  voicedna.zig  voice profiles, consent-gated synthetic/bundled references
  cache.zig     SmartCache: voice/language/context-aware TTS + ASR cache
  reflex.zig    ReflexEngine: turn-end heuristic, speculative planner
  brain.zig     BrainLink: mock, in-process agent, OpenAI-compatible HTTP brains
  conversation.zig Session, sentence chunker, conversation orchestration, barge-in
config/         sando.example.toml
examples/       plugins/noop — sample passthrough plugin
                test-tone.wav — 3 s test fixture (1 s 440 Hz tone)
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

## What Phase 3 does NOT do (honest gaps)

- TTS inference is NOT yet verified live: the Qwen3-TTS weight is
  1.86 GiB and this VM has ~0.6–1.1 GB free, so the new size guard
  refuses the load instead of OOMing (see STATUS.md). ASR, the brain,
  and barge-in are verified live.
- No real cloud brain has been called — the HTTP brain was proven only
  against a local mock server. A real provider needs a key.
- No live microphone/speaker capture — WAV files (offline) and the null
  device only.
- No WASM build verified — no emcc/emsdk on the build machine.
- Enhancement (noise/echo) has NO dedicated model family in the linked
  audio.cpp build, so AudioSense reports it unavailable instead of
  faking it.
- `stream` uses model VAD events only; with no VAD model loaded it
  reports zero segments (the `vad` command's energy fallback is not
  wired into the stream path).
- Speech-to-speech, music generation, and audio separation are
  implemented against the C ABI but untested without weights.
- The Whisper-small weight the brief named does not exist as a
  standalone GGUF in the audio.cpp hub; Moonshine-Streaming-small
  substitutes for ASR (see STATUS.md).

## Consent rule (VoiceDNA)

Voice cloning tests use synthetic reference audio (generated sine
sweep) or bundled test WAVs only. `enrollFromPath` refuses any other
path with `RealVoiceNotAllowed`, and there is no code path that
accepts a real person's recording. See STATUS.md.

## License

MIT — see [LICENSE](LICENSE).
