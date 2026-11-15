# SANDO Audio — API Reference (Phase 2)

Zig 0.17.1. Library `sando` (`libsando.a`), CLI `sando-audio`, C API
(`src/c_api.zig`), plugin ABI (`src/plugin.zig`).

## Library (`src/root.zig`)

`pub const` re-exports: `hardware`, `memory`, `config`, `audiocpp`,
`runtime`, `models`, `plugin`, `engine`, `audio`, `c_api`, `cli`,
`doctor`, `bench`, `streaming`, `vad`, `audiosense`, `voicedna`,
`cache`, `reflex`. Version: `sando-audio 0.2.0`.

### hardware (`src/hardware.zig`)

```zig
pub const BackendKind = enum { auto, cpu, cuda, hip, metal, vulkan, sycl, webgpu };
pub const Backend = struct { kind: BackendKind, available: bool, reason: []const u8 };
pub const CpuInfo = struct { model: []const u8, vendor: []const u8, cores: usize, simd: SimdLevel, ... };

pub fn detectCpu(io: Io, alloc: Allocator) !CpuInfo   // /proc/cpuinfo (Linux), falls back to std
pub fn detectBackends(io: Io, alloc: Allocator) ![]Backend  // live probes
pub fn selectBackend(backends: []const Backend, wanted: BackendKind) ?Backend
pub fn backendName(kind: BackendKind) []const u8
```

`detectBackends` probes for real: CUDA via `/dev/nvidiactl`, HIP via
`/dev/kfd`, Vulkan via the `libvulkan.so.1` loader AND a DRI device
node (`/dev/dri/renderD128` or `/dev/dri/card0`) — the loader alone
is NOT enough (Phase 2 fix: this VM ships the loader with no GPU,
and auto-selection then handed audio.cpp a dead Vulkan backend whose
session creation failed with `Runtime`), SYCL via `DynLib` open,
Metal is macOS-only, WebGPU is browser/WASM-only (always unavailable
natively), CPU is always available. `selectBackend` returns the
wanted backend when available, otherwise the first available backend
in table order (cuda, hip, vulkan, metal, sycl, webgpu, cpu).

### memory (`src/memory.zig`)

```zig
pub const FramePool = struct { // preallocated frames, no per-frame allocation
    pub fn init(alloc: Allocator, frame_len: usize, capacity: usize) !FramePool
    pub fn acquire(self: *FramePool) ?[]f32
    pub fn release(self: *FramePool, frame: []f32) void
};
pub const RingBuffer = struct { // lock-free SPSC, moves frame pointers
    pub fn init(alloc: Allocator, capacity: usize) !RingBuffer
    pub fn push(self: *RingBuffer, frame: []f32) bool
    pub fn pop(self: *RingBuffer) ?[]f32
};
pub const AudioArena = struct { // bump allocator; reset() frees everything
    pub fn init(alloc: Allocator, capacity: usize) !AudioArena
    pub fn allocator(self: *AudioArena) Allocator
    pub fn reset(self: *AudioArena) void
};
```

Default frame: 240 samples = 10 ms at 24 kHz.

### config (`src/config.zig`)

Strict TOML (strings, ints, bools only in Phase 1). Unknown sections
and keys are errors.

```zig
pub const Config = struct {
    mode: Mode, sample_rate: u32, channels: u8,
    backend: BackendKind, webgpu: bool, low_power: bool,
    models: []ModelEntry,
    pub fn parse(alloc: Allocator, text: []const u8) !Config
    pub fn loadFromFile(io: Io, alloc: Allocator, path: []const u8) !Config
    pub fn validate(self: *const Config) !void
    pub fn deinit(self: *Config) void
};
pub const ModelEntry = struct { name, kind: ModelKind, path, voice, streaming, language };
pub const ModelKind = enum { tts, stt, vad };
```

Sections: `[runtime]` (`mode`, `sample_rate`, `channels`),
`[hardware]` (`backend`, `webgpu`, `low_power`), `[[models]]`
(`name`, `kind`, `file`, `voice`, `streaming`, `language`).
`sample_rate` must be one of 8000, 16000, 22050, 24000, 32000, 44100,
48000. `channels` 1 or 2. `mode` `realtime` or `offline`.

### audiocpp (`src/audiocpp.zig`)

audio.cpp C ABI 0.2.0 bindings. `has_link` is a build option: when the
library is not linked, every call returns `error.AudioCppNotLinked`.

```zig
pub const has_link: bool
pub fn version() !Version              // abi, build, tasks, families
pub fn taskCount() usize
pub fn taskName(index: usize) ?[]const u8
pub fn taskToken(token: []const u8) !TaskToken   // "asr", "tts", "vad", ...
pub const Registry = struct { pub fn create(io: Io, alloc: Allocator) !Registry; pub fn modelFamilies(...) };
pub const Options = struct { pub fn create(alloc: Allocator) !Options; pub fn setU32 / setF32 / setString / setBool / setThreads ... };
pub const Model = struct { pub fn load(io: Io, alloc: Allocator, registry: *Registry, opts: *Options, path: []const u8) !Model };
pub const Session = struct { pub fn create(...) !Session; pub fn request(...); pub fn streamPush(...); pub fn streamFinish(...); pub fn poll(...) };
pub const Result = struct { pub fn text(...) !struct { text, language }; pub fn audio(...) !struct { samples, sample_rate, channels }; };
pub fn eventFree(event: *EventHandle) void
```

### runtime (`src/runtime.zig`)

```zig
pub const Task = enum { asr, tts, vad };
pub const Mode = enum { offline, streaming };
pub const Session = struct { pub fn create(...) !Session; pub fn request(...) !Response; pub fn streamPush(...) !?Event; ... };
pub const Response = struct { pub fn text(...) !struct { text, language }; pub fn audio(...) !struct { samples, sample_rate, channels }; pub fn latencyNs(self) u64; };
pub const Runtime = struct {
    pub fn init(io: Io, alloc: Allocator, cfg: *const Config) !Runtime
    pub fn loadModel(self: *Runtime, name: []const u8, kind: Task, path: []const u8) !void
    pub fn createSession(self: *Runtime, task: Task, mode: Mode) !Session
};
```

`loadModel` fails honestly on a missing file (`error.LoadFailed`).
`createSession` without a loaded model returns `error.ModelNotLoaded`.

### models (`src/models.zig`)

ModelHub + SmartCache.

```zig
pub const ModelRegistry = struct {
    pub fn init(alloc: Allocator, max_bytes: usize) !ModelRegistry
    pub fn register(self: *ModelRegistry, name: []const u8, path: []const u8, size_bytes: usize) !void
    pub fn markLoaded / markUnloaded / isLoaded / isRegistered
    pub fn evict(self: *ModelRegistry, needed_bytes: usize) !void // LRU over UNLOADED models only
    pub fn remove(self: *ModelRegistry, name: []const u8) !void   // refuses loaded models
};
```

### engine (`src/engine.zig`)

```zig
pub const Engine = struct {
    pub fn init(io: Io, alloc: Allocator, config_path: ?[]const u8) !Engine
    pub fn start(self: *Engine) !void   // config -> hardware -> runtime -> models -> plugins
    pub fn stop(self: *Engine) void     // reverse order
    pub fn loadModel(self: *Engine, name: []const u8, kind: runtime.Task, path: []const u8) !void
    pub fn createSession(self: *Engine, task: runtime.Task, mode: runtime.Mode) !runtime.Session
    pub fn reloadConfig(self: *Engine, path: []const u8) !void  // backend/flag changes live; shape changes -> error.ConfigReloadRequiresRestart
    pub fn frameLen(self: *const Engine) usize
    pub fn taskCount(self: *Engine) usize
};
pub const default_config_path = "config/sando.toml";
```

Start-up order is config → hardware → runtime → models → plugins;
shutdown is the reverse. `loadConfigModels` stops at the first failing
model and records it in `last_error_model`. Phase 2 adds lazy
per-task loading: `loadModelsForTask` loads only the models of the
kind a task needs (asr → stt, tts → tts, vad → vad), so a `run --task
asr` succeeds when only a TTS model file is missing.

### streaming (`src/streaming.zig`) — LiveStream Engine

```zig
pub const TurnState = struct { // state: listening | speaking; barge_ins counted; interrupted flag
    pub fn isSpeaking(self) bool
    pub fn startSpeaking(self) void
    pub fn finishSpeaking(self) void
    pub fn onSpeechStart(self) bool   // true when speech starts while speaking -> barge-in
    pub fn interrupt(self) bool
};
pub const StreamPump = struct {
    pub fn push(self, samples: []const f32) !void  // one chunk in; events drained into owned PumpedEvents
    pub fn policy(self) !audiocpp.StreamPolicy
};
pub const LiveStream = struct {
    pub fn init(alloc, engine, session) !LiveStream
    pub fn pushMic(self, samples: []const f32) !void  // feeds VadTracker; barge-in resets the TTS session
    pub fn speak(self, text: []const u8, language: ?[]const u8) !void
    pub fn stopSpeaking(self) !void
    pub fn endpointDetected(self, now_sample: i64) bool
    pub fn bargeInCount(self) u64
};
```

`TurnState` is a turn machine: barge-in is only counted while
speaking. `StreamPump` pushes one chunk and drains the event queue
into owned `PumpedEvent`s (text + VAD activity). `LiveStream` runs
ASR in with optional TTS out; the moment the user speaks over TTS,
the TTS session resets — no session restart.

### vad (`src/vad.zig`)

```zig
pub const VadTracker = struct { // pure state machine over stream VAD activity events
    pub fn init(alloc, sample_rate: u32) VadTracker
    pub fn feed(self, activity: audiocpp.VadActivity) !void
    pub fn endpointDetected(self, now_sample: i64) bool  // adaptive endpoint detection, 600 ms default
    pub fn finish(self, end_sample: i64) !void
    pub fn segmentCount(self) usize
};
pub const EnergyVad = struct { // RMS-energy detector, adaptive noise floor + hysteresis
    pub fn init(sample_rate: u32) EnergyVad
    pub fn feed(self, samples: []const f32) ?audiocpp.VadActivity
    pub fn source(_: *const EnergyVad) VadSource  // always .energy
};
```

`EnergyVad` is ALWAYS labelled `source=energy` in CLI output, never
presented as a model result. The minimum-speech check uses the last
loud frame so the 300 ms offset hangover cannot rescue a sub-100 ms
noise blip.

### audiosense (`src/audiosense.zig`)

Capability-first: `Capabilities.fromFamilies` derives what the
linked audio.cpp build can actually do from its live family list
(separation families: htdemucs, bs_roformer, mel_band_roformer,
tf_gridnet, mossformer2, mulacover; diarization: sortformer_diar,
nemotron_3_diar, moss_transcribe_diarize; VAD: builtin silero /
marblenet + firered_vad, pulsevad). Enhancement has NO dedicated
family in the linked set, so it reports false and requests fail
honestly with `NotAvailable` — a real gap, not a stub.
`separateWithSession` runs a `sep` session and returns named stems;
`speakerTurns` reads diarization from any result that carries it.

### voicedna (`src/voicedna.zig`)

JSON-backed voice store under `voices/` (gitignored).

```zig
pub const VoiceSource = enum { synthetic, bundled_test }; // NO real-person variant exists
pub const VoiceProfile = struct { name, display_name, language, source, consent, created_ms, wav_path };
pub const VoiceStore = struct {
    pub fn enrollSynthetic(self, id: []const u8, name: []const u8, language: []const u8) !VoiceProfile  // generates a 2 s sine sweep 220->440 Hz
    pub fn enrollFromPath(self, path: []const u8, id: []const u8, name: []const u8, language: []const u8) !VoiceProfile  // REFUSES any path that is not synthetic or bundled-test
    pub fn list(self) ![]VoiceProfile
    pub fn get(self, id: []const u8) !?VoiceProfile
    pub fn delete(self, id: []const u8) !void  // removes the WAV + the record
};
pub const VoiceStyle = struct { emotion, rate, pitch, energy, language }; // applies to a request via the Phase 2 setters
pub fn identify(result: *const audiocpp.Result, alloc: std.mem.Allocator) ![]audiocpp.SpeakerTurn  // reads speaker turns a result already carries
```

**Consent rule, enforced in code:** reference audio may only be
`.synthetic` or `.bundled_test` (a WAV under `examples/`);
`enrollFromPath` refuses any other path with `RealVoiceNotAllowed`.

### cache (`src/cache.zig`) — SmartCache

One shared LRU byte budget, hits/misses/evictions stats,
in-process only, never written to disk. TTS audio cache keyed by
voice + language + context + text (all four in the key by
construction — a cached phrase is never reused in the wrong
voice/language/context); ASR text cache keyed by language +
Wyhash(audio). TTS entries carry sample_rate/channels so a cache-hit
WAV write is exact.

### reflex (`src/reflex.zig`) — ReflexEngine

```zig
pub fn turnEndProbability(silence_ms: u32, threshold_ms: u32, partial_text: []const u8, last_word_stable: bool) f32 // 0..1 heuristic
pub const SpeculativePlanner = struct {
    pub fn setCandidates(self, candidates: []const []const u8) void
    pub fn prepare(self, cache: *SmartCache, ...) !void // prepares cache hits only; nothing is generated speculatively
    pub fn cancel(self) void // cancels everything on barge-in, counted
};
pub fn pickFastestViable(registry: *models.ModelRegistry, kind: config.ModelKind) ?[]const u8 // name of the smallest loaded model of a kind (size proxy)
pub fn smartTurnAvailable(families: []const []const u8) bool
```

`turnEndProbability` is a heuristic (silence fraction against the
threshold + terminal punctuation floor 0.7 at ≥200 ms + stable last
word +0.1), labelled as such, not a model score.

### audio (`src/audio.zig`)

```zig
pub const WavFormat = enum { pcm16, float32 };
pub const Wav = struct { samples: []f32, sample_rate: u32, channels: u8, pub fn durationSeconds(self) f64; pub fn deinit(self, alloc) void; };
pub fn writeWav(alloc: Allocator, samples: []const f32, sample_rate: u32, channels: u8, format: WavFormat) ![]u8
pub fn parseWav(alloc: Allocator, bytes: []const u8) !Wav
pub fn readWavFile(io: Io, alloc: Allocator, path: []const u8) !Wav
pub fn writeWavFile(io: Io, path: []const u8, samples: []const f32, sample_rate: u32, channels: u8, format: WavFormat) !void
pub fn readSilence(alloc: Allocator, frames: usize, channels: u8) ![]f32
pub const live_audio_status = "unavailable: no audio device backend in Phase 1 (use --wav input for offline mode)";
```

### doctor (`src/doctor.zig`)

```zig
pub const Report = struct { zig_version, os, arch, cpu: CpuInfo, backends: []Backend, audio_cpp: ?audiocpp.Version, config_present, config_valid, model_file_count, live_audio, next_step };
pub fn collect(io: Io, alloc: Allocator) !Report  // never fails hard on a probe
pub fn print(report: *const Report, writer: anytype) !void
```

### bench (`src/bench.zig`)

```zig
pub const BenchResult = struct { name: []const u8, iterations: usize, mean_ns, min_ns, max_ns, ops_per_second, notes };
pub fn benchMemory(io: Io, alloc: Allocator, iterations: usize) !BenchResult  // pool + ring + arena, always runnable
pub fn benchInference(engine: *Engine, task: runtime.Task, text: ?[]const u8, iterations: usize) !BenchResult // needs a live session; returns error.ModelNotLoaded otherwise
```

## C API (`src/c_api.zig`)

Plain C ABI, single engine per process. Link `libsando.a` + libc.

```c
const char *sando_version(void);
const char *sando_last_error(void);          // "" when no error
void *sando_engine_create(const char *config_path); // NULL -> config/sando.toml
void  sando_engine_destroy(void *engine);
const char *sando_engine_backend(void *engine);    // "cpu", "vulkan", ...
int   sando_engine_linked(void *engine);           // 1 when audio.cpp is linked
int   sando_engine_task_count(void *engine);
const char *sando_engine_task_name(void *engine, int index);
int   sando_engine_load_model(void *engine, const char *name, const char *kind, const char *path); // 0 ok, -1 on error
int   sando_config_validate(const char *path);     // 0 ok, -1 on error
```

All string returns point at memory owned by the engine; do not free.
`sando_last_error` reports the last failure as a short string.

Phase 2 inference entry points (each takes the model name and
lazy-loads exactly that model from the engine's config; failures
set `sando_last_error`):

```c
char *sando_engine_infer_text(void *engine, const char *model_name, const char *task, const char *wav_path); // ASR/VAD over a WAV -> owned transcript; free with sando_free_string
int   sando_engine_infer_tts(void *engine, const char *model_name, const char *text, const char *language, const char *wav_out_path); // text -> WAV file; 0 ok, -1 on error
void *sando_stream_create(void *engine, const char *model_name, const char *task); // streaming session; borrows the engine, destroy first
char *sando_stream_push(void *stream, const float *samples, size_t frames, unsigned sample_rate, unsigned char channels); // newest partial text or NULL
char *sando_stream_finish(void *stream); // final text
void  sando_stream_destroy(void *stream);
void  sando_free_string(char *s);
```

## Plugin ABI (`src/plugin.zig`)

A plugin is a `.so` exporting one symbol:

```c
struct sando_plugin_descriptor {
    uint32_t api_version;      // must be 1
    const char *name;          // unique, e.g. "noop"
    const char *version;       // e.g. "0.1.0"
    const char *kind;          // "vad" | "stt" | "tts" | "effect" | "other"
    int (*init)(void);
    void (*deinit)(void);
    int (*process_f32)(float *samples, size_t frames,
                       unsigned sample_rate, unsigned channels);
};
struct sando_plugin_descriptor sando_plugin;
```

Loader rules: missing file, missing symbol, bad `api_version`, unknown
`kind`, duplicate load, or failed `init` all fail with an error.
`process_f32` operates in place on interleaved float samples. See the
working example at `examples/plugins/noop/noop.c` (with manifest at
`examples/plugins/noop/manifest.toml`).

## CLI (`src/cli.zig`)

```
sando-audio version
sando-audio doctor
sando-audio help
sando-audio config validate <path>
sando-audio run [--config <path>] [--model <name>] [--task asr|tts|vad]
                [--mode offline|streaming] [--text <text>] [--wav <in.wav>]
                [--out <out.wav>] [--cache] [--voice <name>]
sando-audio stream [--config <path>] [--wav <in.wav>] [--cache]
sando-audio vad [--config <path>] [--wav <in.wav>]
sando-audio voices list
sando-audio voices enroll-synthetic <id> <name> [--language <lang>]
sando-audio voices delete <id>
sando-audio bench [--config <path>] [--model <name>] [--task asr|tts]
                  [--iterations <n>] [--text <text>]
sando-audio models list [--config <path>]
sando-audio plugins list [--dir <path>]
sando-audio plugins load <path>
sando-audio plugins load --manifest <path>
```

Exit codes: 0 ok, 1 runtime failure, 2 usage error. `run` with TTS
writes a PCM16 WAV (default `out.wav`); ASR/VAD need `--wav`.
`bench` always runs the memory bench; the inference bench is skipped
with a plain message when no model/session can start.
