# SANDO Audio — OneAPI Reference (Phase 5)

Zig 0.17.1. Version `0.5.0`. OneAPI is the single HTTP contract for
SANDO Audio: every capability the library has — inference, language,
conversation, models — is reachable over the same routes, with the
same error shape, from any language. The server is `sando-audio serve`
(`src/server.zig`, contract in `src/oneapi.zig`).

Start it:

```sh
./zig-out/bin/sando-audio serve [--config config/sando.toml] \
  [--host 127.0.0.1] [--port 8080] [--max-sessions 32] \
  [--data-dir ~/workspace/liberia-language-data/datasets]
```

`--data-dir` points at the language dataset directory (the
`datasets/` folder with one JSON file per language). Without it the
language endpoints that need real entries (`vocab`, `pronounce`)
answer `asr_unavailable`; `identify` still works (marker-based) and
`route` still answers (it says when no model exists).

## Auth

`SANDO_API_KEY` (environment only — never a flag, never a file).
When set, every `/v1/*` route requires
`Authorization: Bearer <key>` and answers `401 unauthorized`
otherwise. When unset, the server runs in **open dev mode** and says
so at startup. The WebUI at `GET /` is always public (it has its own
key box). Comparison is fixed-length; there is no per-user auth, no
token issuance, no scopes.

## Errors

Every error is JSON with HTTP status:

```json
{"error": {"code": "session_not_found", "message": "no conversation with that id"}}
```

| code | status | meaning |
| --- | --- | --- |
| `bad_request` | 400 | malformed JSON, missing field, unknown language code, bad task/kind |
| `unauthorized` | 401 | missing or wrong API key |
| `not_found` | 404 | unknown route, unknown model name, unknown language dataset |
| `method_not_allowed` | 405 | method the API does not serve |
| `too_large` | 413 | JSON body over 64 KiB, WAV body over 8 MiB |
| `model_not_found` | 404 | no such model file / name |
| `model_loaded` | 409 | refusing to remove/replace a loaded model |
| `registry_full` | 409 | model registry is full |
| `asr_unavailable` | 503 | no ASR model / ASR cannot load or run |
| `tts_unavailable` | 503 | no TTS model / TTS model does not fit in RAM |
| `engine_unavailable` | 503 | no engine configured |
| `session_not_found` | 404 | no conversation with that id |
| `session_full` | 409 | session cap reached and nothing evictable (unused today: oldest evicts) |
| `internal` | 500 | anything else |

## Endpoints

### Meta

`GET /v1/health` → `{"status":"ok","version":"0.5.0","phase":5,"auth":false}`

`GET /v1/version` →
`{"version":"0.5.0","audio_cpp_linked":true,"tasks":["vad","asr","diar","sep","gen","tts","clon","vc","s2s","align","vdes","spk","svc","midi","turn","wake","cls"]}`

`GET /v1/metrics` →
`{"uptime_ms":12319,"total_requests":14,"sessions":0,"asr":{"count":2,"p50_ms":1112,"p95_ms":1112},"last_error":"tts_unavailable","routes":[{"route":"GET /v1/health","count":1}, ...]}`.
Per-route counts collapse ids (`POST /v1/conversation/:id/ask`), so
cardinality stays bounded. ASR percentiles are over the last 64
latencies; null until the first ASR run.

`GET /` → the static WebUI (health / identify / conversation /
models / metrics, with an API-key box). No JavaScript framework, no
build step, no external requests.

### Models (ModelHub)

`GET /v1/models` →
`{"models":[{"name":"moonshine-small","kind":"stt","file":"models/moonshine-streaming-small-q8_0.gguf","loaded":true,"size_bytes":300622464}, ...]}`.
Listed from the config; `loaded` is the live registry state;
`size_bytes` is 0 when the file is absent (e.g. silero-vad, which
has no weights on disk).

`POST /v1/models/install` `{"path":"/tmp/m.gguf","name":"m","kind":"stt"}` → 201
`{"name":"m","kind":"stt","file":"models/m.gguf","size_bytes":300622464,"loaded":false}`.
Installs a model from a local file **on the server's machine** — the
engine never downloads weights. `.gguf` is stt/tts, `.onnx` is vad
only; anything else is 400. A manifest sidecar
`models/<name>.json` is written with sha256/size/source/installed_ms.
Refuses when a loaded model with that name already exists (409).

`DELETE /v1/models/<name>` → `{"deleted":true}`. Refuses a loaded
model (409). A model installed by an earlier process is removed via
its manifest even though the in-memory registry never saw it.

CLI equivalents: `sando-audio models install <path> [--name n]
[--kind stt|tts|vad]` and `sando-audio models remove <name>`.
Measured: installing the 300 MB Moonshine file takes ~33 s on this
VM (copy + SHA-256 in one streaming pass).

### Languages (Phase 4)

`GET /v1/languages` → `{"languages":[{"code":"en-lr","name":"Liberian English","status":"supported","script":"Latin","asr_model":"moonshine-small","tts_available":false}, {"code":"kq",...}, ...]}` — 11 languages.

`POST /v1/language/identify` `{"text":"They fini fool we pekin them."}` →
`{"language":"kq","name":"Koloqua","confidence":1,"scored":3,"tokens":6,"scores":[1,7,0,0,0,0,0,0,0,0,0]}`.
Marker-based, no model. Measured on the real dataset: 76.9%
identification accuracy (846/1,100); Koloqua itself only 27% —
most attested entries are 3-word glosses with no strong marker.

`POST /v1/language/vocab` `{"word":"fini","language":"kq"}` → real
cited entries (`id`, `side`, `input`, `response`,
`standard_english`, `source`) from the dataset, max 8. Needs
`--data-dir`, else `asr_unavailable`.

`POST /v1/language/pronounce` `{"word":"pekin","language":"kq"}` →
`{"word":"pekin","form":"They fini fool we pekin them.","meaning":"They have deceived our children.","id":"koloqua_00005","syllables":[...],"heuristic":true,"source":"..."}`.
Syllables are a heuristic split unless attested. Needs `--data-dir`.

`POST /v1/language/route` `{"text":"I de go."}` →
`{"language":"kq","confidence":1,"asr":"none","report":"language: kq (Koloqua) — asr: none, fallback moonshine-small (...)"}`.
Honest about the missing Koloqua ASR model: the fallback is English
Moonshine, and the report says the transcript is partial.

### Conversations (Phase 3)

`POST /v1/conversation` `{"language":"en","voice":"v1"}` → 201
`{"id":"fbcab9760c625bbd","language":"en-lr","voice":"v1","turns":0}`.
`"en"` normalizes to `"en-lr"` (legacy code). Unknown codes are 400.
Sessions are in-memory, capped at `--max-sessions` (default 32);
the oldest evicts when the cap is hit. The brain over HTTP is the
mock brain only — a real LLM brain is a library-level choice
(`brain.AgentBrain`), not an HTTP one, so no key ever crosses the
wire.

`POST /v1/conversation/<id>/ask` `{"text":"hello"}` →
`{"id":"...","transcript":"hello","reply":"Hey! Good to hear you. What's going on?","asr":"skipped","brain":"ran","tts":"unavailable","barged_in":false,"turns":2,"partial_reply":null,"interrupt_text":null}`.
`asr`/`brain`/`tts` are leg statuses (`skipped`/`ran`/`unavailable`
for text turns; `tts` is `unavailable` on this VM).

`GET /v1/conversation/<id>` → `{"id":"...","language":"en-lr","voice":"v1","turns":[{"role":"user","text":"hello"},{"role":"assistant","text":"..."}]}`.

`GET /v1/conversations` → `{"sessions":[{"id":"...","language":"en-lr","voice":"v1","turns":2}]}`.

`DELETE /v1/conversation/<id>` → `{"deleted":true}`; a second GET
is 404 `session_not_found`.

### Inference (Phase 2)

`POST /v1/infer?task=asr[&language=en]` with a WAV body →
`{"task":"asr","model":"moonshine_asr","text":"Hello, this is sandos speaking.","language":"en","latency_ms":5977}`.
First call includes model load (~6 s); warmed calls ~1.1 s.
Recorded in metrics (count + p50/p95). 503 `asr_unavailable` when
no ASR model can load.

`POST /v1/infer?task=vad` with a WAV body →
`{"task":"vad","source":"energy","segments":[{"start_s":1,"end_s":2.3}]}`.
Energy fallback (no silero weights on disk); `source` says so.

`POST /v1/infer?task=tts[&language=en]` with `{"text":"..."}` (or
`?text=...`) → raw `audio/wav` bytes on success. On this VM it is
503 `tts_unavailable`: `tts model qwen3-tts-0.6b is 1898 MB but only
672 MB is free — this machine cannot load it`. The size check runs
before any load, and the message carries the measured numbers.

Unknown `task` is 400. WAV bodies are capped at 8 MiB (413);
JSON bodies at 64 KiB.

## SDKs

| SDK | Path | Notes |
| --- | --- | --- |
| C | `sdk/c/sando_audio.h` | All 26 `sando_*` exports. Example: `examples/c/converse.c` |
| JS/TS | `sdk/js/sando.mjs` | `SandoClient` (fetch, Node 18+). Example: `examples/js/talk.mjs` |
| Python | `sdk/python/sando.py` | `SandoClient` (urllib, stdlib only). Example: `examples/python/talk.py` |
| Zig | `src/root.zig` (`sando` module) | Example: `examples/zig/` (own `build.zig`, links the library the same way the repo's tests do) |

Rust/Go: **not shipped** — neither toolchain exists on this VM
(`rustc`/`go` absent, verified 2026-11-15) and installing one is
out of scope for this phase. The C header is the interop path for
those languages today.

## Library, C API, plugins (Phases 1–4, unchanged by Phase 5)

The library (`src/root.zig`, `libsando.a`) still exports every
module (`hardware`, `memory`, `config`, `audiocpp`, `runtime`,
`models`, `plugin`, `engine`, `audio`, `c_api`, `cli`, `doctor`,
`bench`, `streaming`, `vad`, `audiosense`, `voicedna`, `cache`,
`reflex`, `brain`, `conversation`, `language`, `vocabulary`,
`pronunciation`, `adaptive_ear`, `languageforge`, `evaluate`,
`oneapi`, `server`). The C API (`src/c_api.zig`, 26 exports, header
`sdk/c/sando_audio.h`) covers engine/version/config/inference/
streaming/conversation/language. The plugin ABI (`src/plugin.zig`)
loads `.so` descriptors; `examples/plugins/` has the passthrough
sample.

## What OneAPI does NOT do (honest gaps)

- **No WebSocket.** The brief left it a stretch goal; the core was
  the priority and streaming over HTTP (chunked ASR + the `stream`
  C API) already covers the live path. One request per connection,
  then close.
- **No WebRTC, telephony/SIP, distributed inference, load
  balancing, cloud hosting, voice marketplace, business/calling
  agents, AI video voice, or game NPC voices.** All explicitly out
  of Phase 5; the server is a local dev server, not a production
  deployment (see `docs/DEPLOY.md`).
- **No real cloud LLM calls.** The HTTP brain is the mock brain;
  cloud transport is tested against a local mock only.
- **TTS and Koloqua ASR do not run on this VM** (see the 503s
  above). The API reports that instead of simulating it.
- **Sessions and jobs are in-memory.** A restart forgets
  conversations; there is no persistence, no queue, no retry.
- **Install uses the source file's basename** for the destination,
  so two different files with the same basename collide in
  `models/`. Pass `--name` / `"name"` to disambiguate the registry
  entry; the file itself still takes the basename.
