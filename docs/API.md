# SANDO Audio — API Reference (Phase 3)

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

### brain (`src/brain.zig`) — BrainLink

```zig
pub const Brain = struct { // vtable: reply(alloc, io, prompt, cancel, chunk_ctx, on_chunk) ![]const u8; name(); deinit(alloc)
    pub fn reply(self: Brain, alloc: Allocator, io: Io, prompt: []const u8, cancel: ?*const bool, chunk_ctx: *anyopaque, on_chunk: ChunkFn) ![]const u8 // streams chunks via on_chunk, returns the owned full reply
};
pub const ChunkFn = *const fn (ctx: *anyopaque, chunk: []const u8) anyerror!void;
pub const MockBrain = struct { // scripted rules, matched case-insensitively against the LAST user turn
    pub fn asBrain(self: *MockBrain) Brain
};
pub const AgentBrain = struct { // in-process host callback; the host owns cancellation/streaming
    ctx: *anyopaque, callback: AgentCallback,
    pub fn asBrain(self: *AgentBrain) Brain
};
pub const HttpBrain = struct { // OpenAI-compatible chat completions, POST /v1/chat/completions, stream: true
    pub fn init(url: []const u8, model: []const u8, sender: Sender) HttpBrain
    pub fn asBrain(self: *HttpBrain) Brain
};
pub const Sender = struct { // pluggable transport; StdHttpSender is the real one (std.http.Client)
    pub fn send(self: Sender, alloc: Allocator, io: Io, url: []const u8, body: []const u8, bytes_ctx: *anyopaque, on_bytes: BytesFn) !void
};
pub const SseParser = struct { // incremental SSE: split feeds, data: [DONE], :ping keepalives, plain-JSON fallback
    pub fn feed(self: *SseParser, bytes: []const u8, ctx: *anyopaque, on_content: *const fn (ctx: *anyopaque, content: []const u8) anyerror!void) !void
    pub fn finish(self: *SseParser, ctx: *anyopaque, on_content: ...) !void
};
pub fn buildChatRequest(alloc: Allocator, model: []const u8, prompt: []const u8) ![]const u8 // {"model","messages":[{"role":"user","content":prompt}],"stream":true,"temperature":0.7}
```

**No Authorization header is ever sent** by the HTTP brain, so it
only talks to a local or otherwise unauthenticated OpenAI-compatible
endpoint. No keys, no real cloud calls in this phase.

### conversation (`src/conversation.zig`)

```zig
pub const Session = struct { // id (16 hex chars), voice, language, bounded history (max_turns = 20, oldest evicted first)
    pub fn init(alloc: Allocator, io: Io, voice: []const u8, language: []const u8) !Session
    pub fn renderPrompt(self: *const Session, alloc: Allocator) ![]const u8 // instruction + "User: .../Assistant: ..." history
};
pub fn splitSentences(alloc: Allocator, text: []const u8) ![][]const u8 // boundaries at . ? ! + whitespace; runs > 200 chars cut at the last space; "Dr." splits early (documented heuristic)
pub const SentenceChunker = struct { // incremental: feed() emits closed sentences as they arrive, finish() flushes the tail
    pub fn feed(self: *SentenceChunker, text: []const u8, ctx: *anyopaque, on_sentence: *const fn (ctx: *anyopaque, sentence: []const u8) anyerror!void) !void
};
pub const LegStatus = enum { skipped, ran, cached, unavailable };
pub const TurnResult = struct { transcript, reply, partial_reply: ?[]const u8, interrupt_text: ?[]const u8, asr, brain, tts: LegStatus, sentences_spoken, sentences_from_cache, sentences_skipped, tts_out_errors, barged_in: bool };
pub const InterruptFn = *const fn (ctx: *anyopaque) ?[]const u8; // polled after each spoken sentence while streaming
pub const TtsAudioFn = *const fn (ctx: *anyopaque, sentence: []const u8, samples: []const f32, sample_rate: u32, channels: u8) anyerror!void;
pub const Conversation = struct { // owns session; borrows brain + optional ASR/TTS sessions + SmartCache
    asr: ?*runtime.Session, tts: ?*runtime.Session, cache: ?*cache.SmartCache,
    turn_end_threshold: f32 = 0.6, echo: ?*Io.Writer, interrupt_fn: ?InterruptFn, on_tts_audio: ?TtsAudioFn,
    pub fn init(alloc: Allocator, io: Io, brain_value: Brain, voice: []const u8, language: []const u8) !Conversation
    pub fn processText(self: *Conversation, user_text: []const u8) !TurnResult // empty text calls no brain
    pub fn processAudio(self: *Conversation, samples: []const f32, sample_rate: u32, channels: u8) !TurnResult // ASR (cache first) -> brain -> TTS per sentence (cache first)
    pub fn shouldReply(self: *const Conversation, silence_ms: u32, threshold_ms: u32, partial_text: []const u8, last_word_stable: bool) bool // reflex.turnEndProbability >= threshold
};
```

Turn flow is listen → transcribe → think → speak → listen. A
barge-in cancels the reply mid-stream (`error.Cancelled`): the
partial reply stays in history, the interruption becomes a new user
turn, and the brain answers it as a follow-up — multi-turn context
survives. TTS errors are recorded (`tts_out_errors`), never fatal.

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

### language — Phase 4 (`src/language.zig`, `src/vocabulary.zig`, `src/pronunciation.zig`, `src/adaptive_ear.zig`, `src/languageforge.zig`, `src/evaluate.zig`)

```zig
// language.zig: 11-language registry (en-lr, kq, bsq, kpe, vai, grb, kro, lom, mnk, gol, dnj)
pub const Language = struct { code: [:0]const u8, name: [:0]const u8, dataset_file: ?[]const u8, status: Status, script: []const u8, asr: ?[]const u8, tts: bool };
pub const registry: [11]Language;
pub fn normalizeCode(input: []const u8) ?[]const u8 // "en" -> "en-lr", names, "gio" -> "dnj"
pub fn identify(alloc: Allocator, text: []const u8, vocab: ?*const vocabulary.Vocabulary) !Identification // marker + wordlist scoring; strong Koloqua marker (weight >= 2) decides Koloqua outright; a wordlist language must beat English by >= 2 points
pub fn detectSwitches(alloc: Allocator, text: []const u8, vocab: ?*const vocabulary.Vocabulary) !CodeSwitchResult // segments + switch count; shared words ("go", "them") do not switch a run
pub fn promptFor(language: []const u8) []const u8 // language-aware brain prompt line
// vocabulary.zig: dataset-backed lookup; files live OUTSIDE the repo (read-only, --data-dir), never bulk-copied in
pub const Entry = struct { id, kind, input, response, standard_english, source: []const u8 }; // kind is the dataset "types" field
pub const Dataset = struct { pub fn loadJson(alloc, language, bytes) VocabError!Dataset; pub fn loadFile(alloc, io, language, path) VocabError!Dataset; pub fn lookup(self, alloc, word, max) ![]Match; pub fn lookupEnglish(self, alloc, word, max) ![]Match; pub fn containsWord(self, word) !bool }; // word set: response words only; 1-2 byte all-ASCII tokens excluded (collision rule, see STATUS.md)
pub const Vocabulary = struct { pub fn load(self, io, code, path) VocabError!void; pub fn dataset(self, code) ?*Dataset };
// pronunciation.zig
pub fn lookup(alloc, vocab, language, word) !?Pronunciation // attested form + source, or null
pub fn syllabify(alloc, word) ![]const u8 // mechanical vowel-group split, always labelled heuristic
// adaptive_ear.zig
pub const Routing = struct { language, asr_model: ?[]const u8, fallback: ?[]const u8, confidence: f32, note: []const u8 };
pub fn route(language: []const u8) Routing // honest: kq + indigenous -> asr none, Moonshine fallback
pub const CorrectionLexicon = struct { pub fn add(self, wrong, right) !void; pub fn correct(self, alloc, text) ![]const u8 };
// languageforge.zig: contribution schema + validation + JSON only (no storage backend, no audio collected)
pub const Contribution = struct { id, language, transcript, audio_sha256, audio_format, duration_ms, speaker_id: []const u8, consent: Consent };
pub fn validate(alloc, c: *const Contribution) ![]Problem // consent required; scope must allow asr or training
pub fn parse(alloc, bytes) !Contribution; pub fn stringify(alloc, c: *const Contribution) ![]const u8
// evaluate.zig: measured accuracy on real labeled examples (first N in file order, deterministic)
pub fn evaluateIdentification(alloc, vocab, limit) !IdentificationEval // kq attested responses + paired standard_english; wordlist languages first N responses
pub fn evaluateCodeSwitch(alloc, vocab, limit) !CodeSwitchEval // real Koloqua response + real English sentence of a different entry; boundary known by construction, +/-1 word tolerance
```

Measured on the real dataset (limit 100): identification 76.9%
(846/1100); code-switch 8/100 boundaries, precision 0.03, recall
0.08. See STATUS.md for the per-language table and the three
scoring rules the numbers rest on.

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

All string returns point at memory owned by the engine, except the
ones marked owned below — those are freed with `sando_free_string`.
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

Phase 3 conversation entry points. A conversation is one session
(bounded history, in-memory only) plus a brain, and borrows the
engine's Io — destroy it before the engine. No ASR/TTS session is
attached here, so the TTS leg reports skipped; the full audio
pipeline lives in the `converse` CLI command.

```c
typedef const char *(*sando_agent_reply_fn)(void *ctx, const char *prompt); // return a reply, or NULL on failure; the library copies it
void *sando_conversation_create_mock(void *engine, const char *voice, const char *language); // scripted brain; voice/language may be NULL ("v1"/"en")
void *sando_conversation_create_agent(void *engine, void *ctx, sando_agent_reply_fn cb, const char *voice, const char *language); // host callback brain; cb must not be NULL
char *sando_conversation_ask(void *conversation, const char *text); // one text turn -> owned reply; free with sando_free_string
size_t sando_conversation_history_count(void *conversation); // 2 per ask (user + assistant); 0 for NULL
void  sando_conversation_destroy(void *conversation);
```

Phase 4 language entry points. No engine needed — identification is
text-only (marker + wordlist scoring over the built-in registry; the
wordlist half needs no dataset loaded for Koloqua/English, and
returns "und" for indigenous languages until a dataset is loaded
through the CLI path). Returns point at static strings; do not free.

```c
size_t      sando_language_count(void); // 11
const char *sando_language_code(size_t index); // "en-lr", "kq", "bsq", ...; NULL past the end
const char *sando_language_name(const char *code); // "Koloqua"; NULL for unknown codes
const char *sando_language_identify(const char *text); // language code, or "und" when nothing scores
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
sando-audio converse [--config <path>] [--wav <turn.wav> ...] [--interrupt <in.wav>]
                     [--brain mock|http] [--brain-url <url>] [--brain-model <name>]
                     [--voice <name>] [--language <lang>] [--cache] [--out-dir <dir>]
sando-audio talk <text> [--language <lang>] [--voice <name>] [--correct wrong=right ...]
sando-audio language list
sando-audio language identify <text> [--data-dir <dir>]
sando-audio language vocab <word> [--language <lang>] --data-dir <dir>
sando-audio language pronounce <word> [--language <lang>] --data-dir <dir>
sando-audio language route <text>
sando-audio language evaluate [--data-dir <dir>] [--limit <n>]
sando-audio languageforge validate <file>
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
with a plain message when no model/session can start. `converse`
runs speech-to-brain-to-speech over WAV files: each `--wav` is VAD
segmented (energy fallback, labelled), segments group into turns on
silence gaps via the turn-end probability, the brain streams live,
and spoken TTS audio lands in `--out-dir` (`turn<N>-sent<M>.wav`).
The TTS model is not loaded when its file exceeds free memory
(`/proc/meminfo`) — the leg is skipped honestly instead of OOMing.
An `--interrupt` file is transcribed on the first poll mid-reply
(barge-in); if never consumed it runs as a final normal turn.
