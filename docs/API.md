# SANDO Audio — API Reference (Phase 1)

Zig 0.17.1. Library `sando` (`libsando.a`), CLI `sando-audio`, C API
(`src/c_api.zig`), plugin ABI (`src/plugin.zig`).

## Library (`src/root.zig`)

`pub const` re-exports: `hardware`, `memory`, `config`, `audiocpp`,
`runtime`, `models`, `plugin`, `engine`, `audio`, `c_api`, `cli`,
`doctor`, `bench`. Version: `sando-audio 0.1.0`.

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
`/dev/kfd`, Vulkan and SYCL via `DynLib` open, Metal is macOS-only,
WebGPU is browser/WASM-only (always unavailable natively), CPU is
always available. `selectBackend` returns the wanted backend when
available, otherwise the first available backend in table order
(cuda, hip, vulkan, metal, sycl, webgpu, cpu).

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
model and records it in `last_error_model`.

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
`sando_last_error` reports the last failure as a short string. Inference
entry points land in Phase 2.

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
                [--out <out.wav>]
sando-audio bench [--config <path>] [--model <name>] [--task asr|tts]
                  [--iterations <n>] [--text <text>]
sando-audio models list [--config <path>]
sando-audio plugins list [--dir <path>]
sando-audio plugins load <path>
```

Exit codes: 0 ok, 1 runtime failure, 2 usage error. `run` with TTS
writes a PCM16 WAV (default `out.wav`); ASR/VAD need `--wav`.
`bench` always runs the memory bench; the inference bench is skipped
with a plain message when no model/session can start.
