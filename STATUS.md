# SANDO Audio — Phase 5 STATUS

Phase 5 (Developer Ecosystem, Production & Applications): **COMPLETE,
builder-verified and VERIFIED INDEPENDENTLY BY D from a clean
worktree**, 2026-11-15 — the last phase of the 5-phase roadmap. Built
and tested on this VM (Zig 0.17.1, `-Dcpu=baseline`, `-j1`). Pushed
by D after verification. Since then origin/main has moved on: audio.cpp
0.9.5 (see below) and the CI workflow (see below).

D re-ran everything from a clean worktree with a clean cache: `zig
build` exit 0; test binary run directly from the repo root = **All
126 tests passed, exit 0**. Live REST server (fresh binary, ports
18230/18231): health ok, identify "They fini fool we pekin them."
→ kq 1.00, conversation create ("en" → "en-lr") / ask (mock brain
answered, `asr=skipped brain=ran tts=unavailable`) / get (history
2 turns), metrics with per-route counts, WebUI 200 text/html,
unknown route 404, ASR live via `/v1/infer` ("Hello, this is sandos
speaking.", Moonshine, 3,970 ms first call), TTS honest 503, VAD
energy segments, auth 401 without key / 401 wrong key / 200 right
key, Python SDK example green against the live server (health,
identify, conversation lifecycle, VAD, TTS 503, metrics), and `nm`
confirms all 26 `sando_*` symbols in `libsando.a`. Both verification
servers stopped afterwards; no dev servers left running.
Builder's live numbers, also recorded: warmed ASR 1,112 ms; ModelHub
install (300 MB, 201) + remove (200); all four SDK examples run green
against the live server (C, JS, Python, Zig).

## Continuous integration — LIVE 2026-11-15

`.github/workflows/ci.yml` (commit `f9f9a11`, created through the
GitHub web UI — the CLI token cannot create workflow files) runs on
every push to main and on pull requests: ubuntu-24.04, 4 vCPU,
16 GB RAM, 14 GB SSD. It builds audio.cpp v0.9.5 from source,
builds the engine with `-Dcpu=baseline`, downloads the Moonshine
ASR (300,622,464 bytes) and Qwen3-TTS base (1,991,217,728 bytes)
models with byte-size checks, runs the full test suite from the
repo root, checks `doctor` for `audio.cpp: linked (abi 0x300,
build 0.9.5, 17 tasks, 148 families)`, then proves TTS end to
end (`run --task tts` → WAV, transcribed back through ASR,
checked for "sando"). Runs:
https://github.com/psrockstar098/sando-audio/actions

Run #1 started 2026-11-15 ~11:50 (in progress at the time of
writing; the audio.cpp source build alone takes ~30–60 min).
A one-time check is scheduled ~12:55 the same day to report the
outcome.

Scope, per Dominic: the CI run tests JUST THE ENGINE with the
stock Qwen3-TTS base model. The real voice is the fine-tuned
Qwen3-TTS-0.6B LoRA, which is not finished yet. Swapping it in
later is a model-artifact/config change (the `[[models]]` entry
in `config/sando.example.toml` + the download URL/size), not a
workflow change. No LoRA-loading mechanism exists in the repo.

## audio.cpp 0.9.5 — LANDED 2026-11-15 (source build, after Phase 5 push)

The open follow-up from Phases 2–5 is CLOSED. The v0.9.5 release tag
(`2b7e38e`) was built from source on this VM (the 0.9.5 prebuilt still
cannot load here — glibc 2.43 required, VM has 2.39). Minimal
configure: `AUDIOCPP_BUILD_C_API=ON`, all GPU backends OFF, llamafile
OFF, all CPU variants ON, Release, `-g0`, `-j1`; build took ~80 min
across a VM restart (resumed incrementally from 320 objects — the
build dir under `~/workspace/tmp/audio.cpp-0.9.5/build` persists).
Header diff 0.9.3 → 0.9.5 is 43 lines: ABI 0.2.0 → 0.3.0, adds
`audiocpp_log_set` + `audiocpp_session_create_with_impl`, nothing
removed or re-signed — the existing bindings link unchanged. The
vendored libs in `third-party/audiocpp` (gitignored) are now the
0.9.5 build: `libaudiocpp.so` + `libggml-base.so` + all 14 CPU
variants; `audiocpp_abi_version()` reports `0x300`,
`audiocpp_build_version()` reports `0.9.5` (stamped with
`-DAUDIOCPP_VERSION=0.9.5` — the default stamp is the useless
`"dev"`). Doctor: **audio.cpp linked (abi 0x300, build 0.9.5, 17
tasks, 148 families)** — 148 families, up from 133 in 0.9.3.

One code change came with the swap: `src/runtime.zig` test
"runtime lists the live task vocabulary when linked" hardcoded the
old ABI/version (`0x200` / `"0.9.3"`); updated to `0x300` /
`"0.9.5"`. Re-verified by D from a clean worktree of the landed
commit (`de8f614`): `zig build` exit 0, test binary direct = **All
126 tests passed**, doctor shows abi 0x300 / build 0.9.5 / 148
families, and live ASR via the REST server transcribed "Hello, this
is sandos speaking." (Moonshine, 5,116 ms first call). Pushed —
origin/main was the 0.9.5 head at that point (the CI workflow commit
followed — see above).

## Phase 5 verification summary (builder, this session)

| Check | Result |
|---|---|
| `zig build -j1 -Dcpu=baseline` | clean, exit 0 |
| test binary run directly (repo root) | **126/126 tests pass, exit 0, no leaks** (was 109/109) |
| `serve` live (port 18222, `--data-dir` datasets) | health ok, version 0.5.0, audio_cpp_linked true, 17 tasks |
| `GET /v1/languages` live | 11 languages, en-lr supported / rest partial |
| `POST /v1/language/identify` live | "They fini fool we pekin them." → **kq, 1.00** |
| `POST /v1/language/vocab` live | `fini` (kq) → real cited entries (koloqua_00005 etc.) |
| `POST /v1/language/pronounce` live | `pekin` (kq) → attested form, syllables heuristic |
| `POST /v1/language/route` live | "I de go." → kq, asr none, fallback moonshine-small, honest report |
| Conversation lifecycle live | create 201 (`en` → `en-lr`), ask → mock reply, get/list show 2 turns, delete 200, get after delete 404 `session_not_found` |
| `GET /v1/metrics` live | uptime, total_requests, sessions, ASR count 2 / p50 1112 / p95 1112, per-route counts with collapsed ids |
| `GET /` WebUI live | 200, text/html |
| `POST /v1/infer?task=vad` live | tone fixture → energy segments 1.0–2.3 s, `source: "energy"` |
| `POST /v1/infer?task=asr` live | **real speech → "Hello, this is sandos speaking."**, model moonshine_asr, 5,977 ms cold / 1,112 ms warmed |
| `POST /v1/infer?task=tts` live | **503 `tts_unavailable`** — "tts model qwen3-tts-0.6b is 1898 MB but only 672 MB is free" |
| Auth live (port 18223, `SANDO_API_KEY=test-key-123`) | no key → 401, wrong key → 401, right key → 200 (`auth: true`); WebUI stays public |
| ModelHub CLI live | install 300 MB Moonshine copy → 201-equivalent, sha256 in manifest verified byte-identical (`98731a08...`); remove → `removed p5-test-model` |
| ModelHub HTTP live | install → 201, remove → 200, server stayed up |
| C example live | `examples/c/converse.c` → 0.5.0, 11 languages, identify "kq", backend cpu linked, 2-turn mock conversation, history 4 |
| JS example live | `examples/js/talk.mjs` → health/identify/conversation/VAD/TTS-503/metrics, exit 0 |
| Python example live | `examples/python/talk.py` → same flow, exit 0 |
| Zig example live | `examples/zig/` builds + runs → 0.5.0, identify kq 1.00, 2-turn conversation, history 4 |
| Weights / dataset in git | none — `models/` gitignored; dataset read-only outside the repo |
| audio.cpp version shipped | **0.9.3 prebuilt at verification time** (0.9.5 landed right after — see the 0.9.5 section above) |

## Phase 5 modules (what landed)

- OneAPI (`src/oneapi.zig`): `ApiErrorCode` (14 codes → HTTP
  status), `jsonEscape`, `errorJson`, `readApiKey` (env only),
  `checkAuth` (fixed-length Bearer compare), `memAvailableBytes`
  (/proc/meminfo), `FitCheck` (model size vs free RAM),
  `Metrics` (per-route counts, last-64 ASR latencies, p50/p95),
  `parseJsonBody` + request shapes. `memAvailableBytes` moved here
  from cli.zig (single copy).
- ModelHub (`src/models.zig`, install/remove appended):
  `installModel` (extension + kind validation, streaming
  copy+SHA-256, `models/<name>.json` manifest),
  `removeModel` (refuses loaded models; a manifest alone suffices
  for models installed by an earlier process — the registry is
  in-memory only), `sha256HexFile`.
- Server (`src/server.zig`): `std.http` over `std.Io.net`,
  127.0.0.1 default, one request per connection then close,
  per-connection arena, JSON bodies capped at 64 KiB, WAV bodies at
  8 MiB, multi-session (32 default, oldest evicts), env-only key,
  metrics, static WebUI. Lazy ASR load with sticky failure.
- CLI (`src/cli.zig`): `serve [--config] [--host] [--port]
  [--max-sessions] [--data-dir]`, `models install <path> [--name]
  [--kind]`, `models remove <name>`, usage + version bumped to 0.5.0.
- SDKs: `sdk/c/sando_audio.h` (all 26 exports) + `examples/c/`,
  `sdk/js/sando.mjs` + `examples/js/`, `sdk/python/sando.py` +
  `examples/python/`, `examples/zig/` (own build.zig, links the
  library like the repo's tests).
- Docs: `docs/API.md` rewritten as the OneAPI reference,
  `docs/DEPLOY.md` (run it, limits, what production would need).

## Phase 5 bugs found live (and fixed in this phase)

1. **Server teardown hung forever** (found by the test run:
   10 min, 0 CPU): closing the listener from another thread does
   NOT unblock a blocked `accept()` on Linux. Fix: `shutdown`
   opens a loopback connection to wake accept; the loop sees the
   stop flag and exits. The `run` loop now also checks the flag
   after every accept.
2. **`models install` crashed the server** (found live on a real
   300 MB install): `readSliceShort` was reading into the reader's
   own buffer → `@memcpy arguments alias` panic, which killed the
   whole server process mid-copy (partial file left behind). Fix:
   separate reader and destination buffers in `installModel` and
   `sha256HexFile`. The 32-byte unit test never triggered it (the
   first fill reads straight into the destination); a new 200 KiB
   regression test covers the copy path.
3. **CLI `models remove` could not remove anything installed by
   an earlier process** (found live: exit 1, ModelNotFound): the
   registry is built from the config at startup, so an installed
   model was unknown to a fresh process. Fix: `removeModel` falls
   back to the manifest (`models/<name>.json`) and deletes the
   file it names.
4. **C API symbols were missing from `libsando.a`** (found when
   the C example failed to link: all 26 `sando_*` undefined): no
   code referenced `root.c_api`, so Zig's lazy analysis never
   emitted the `export` functions — the C API was never actually
   linkable before Phase 5. Fix: a `comptime { _ = c_api; }` block
   in `src/root.zig` forces analysis; `nm` now shows all 26.
5. **`POST /v1/conversation` with `"language":"en"` answered
   400** (found by the integration tests): the registry code is
   `"en-lr"`, not `"en"`. Fix: the handler now runs
   `language.normalizeCode` (the same legacy mapping the CLI uses).
6. **Zig 0.17.1 API notes** (all hit while compiling): `**`
   (array repeat) does not exist — use `std.mem.zeroes`;
   `ArrayList` is `.empty` + `append(alloc, item)`, no `.writer`
   and no `.init(alloc)`; `std.json.Stringify.valueAlloc` takes 3
   args; `http.Status.content_too_large` is `payload_too_large`;
   `Dir.readFileAlloc` takes `(io, path, alloc, .limited(n))`;
   `IpAddress.connect` needs `.mode = .stream`; discarding an
   error value with `_ = err` is an error — use `catch {}`.

## Phase 5 honest gaps

- **WebSocket not built.** Stretch goal only; the core was the
  priority and HTTP streaming already covers the live path.
- **No WebRTC, telephony/SIP, distributed inference, load
  balancing, cloud hosting, voice marketplace, business/calling
  agents, video voice, or game NPC voices** — explicitly out.
- **Rust/Go SDKs not shipped** — neither toolchain exists on this
  VM; the C header is the interop path.
- **TTS and Koloqua ASR do not run on this VM** (503s above).
- **Sessions in-memory only**; a restart forgets conversations.
- **Install uses the source file's basename** for the
  destination — two files with the same basename collide.
- **Install copy is slow**: ~33 s for 300 MB on this VM (byte
  streaming through the reader/writer interfaces, no progress).
- **D's independent re-verification is DONE**: D re-ran everything
  from a clean worktree + clean cache (test binary direct = All 126
  tests passed; live server smoke; SDK examples) and pushed — see
  the top of this file.

## How to verify from a clean checkout

```sh
zig build -j1 -Dcpu=baseline
zig build test -j1 -Dcpu=baseline   # then run the test binary directly
./zig-out/bin/sando-audio version   # 0.5.0
./zig-out/bin/sando-audio serve --port 8080 --data-dir <datasets>
curl http://127.0.0.1:8080/v1/health
curl -X POST http://127.0.0.1:8080/v1/language/identify -d '{"text":"They fini fool we pekin them."}'
```

---

# SANDO Audio — Phase 4 STATUS

Phase 4 (Liberian Language & Voice Intelligence): **COMPLETE, builder-
verified and VERIFIED INDEPENDENTLY BY D from a clean worktree**,
2026-11-15. Built and tested on this VM (Intel Xeon Platinum 8321HC,
4 cores, AVX-512, Ubuntu 24.04, glibc 2.39, Zig 0.17.1). Pushed by D
after verification — origin/main is the Phase 4 head.

D re-ran everything from a clean worktree with a clean cache: `zig
build` exit 0; test binary direct = **All 109 tests passed, exit 0**;
`language identify` "They fini fool we pekin them." → kq 1.00;
`language vocab fini` → real cited entries; `language pronounce
pekin` → attested form; `talk "I de go." --language kq` → Sando
answers "I de go." verbatim; `language route` honest about no
Koloqua ASR model; `language evaluate --limit 100` reproduced the
per-language numbers exactly (kro 77, lom 69, mnk 74, gol 85, dnj
100) and code-switch 8/100, precision 0.03, recall 0.08; `converse`
with real Liberian English audio → exact transcription, en-lr
detected, mock brain answered, `tts=unavailable`. D also confirmed
the 840-attested count from the dataset file directly (840
non-expansion + 10,940 expansion = 11,780).

## Phase 4 verification summary (builder, this session)

`zig build` exit 0; test binary run directly = **All 109 tests passed,
exit 0** (was 91/91 — 18 new Phase 4 tests); `converse` live with real
English audio (exact ASR transcription, language-aware brain prompt,
AdaptiveEar routing report). All identification/lookup numbers below
are measured on the REAL dataset
(`~/workspace/liberia-language-data/datasets/`, read-only, 38,494
entries, 17 languages) with `language evaluate --limit 100`
(10 languages loaded; 1,100 examples).

| Check | Result |
|---|---|
| `zig build -j1 -Dcpu=baseline` | clean, exit 0 |
| `zig build test -j1 -Dcpu=baseline`, test binary run directly | **109/109 tests pass** (was 91/91), exit 0 |
| `language list` | 11 languages: en-lr [supported, Moonshine ASR], kq/bsq/kpe/vai/grb/kro/lom/mnk/gol/dnj [partial, no ASR/TTS] |
| `language identify` live | "They fini fool we pekin them." → **kq, 1.00** (kq 7.0 / en 1.0); "dō" → **bsq, 1.00**; "The book is on the table and I have read it." → **en-lr, 0.64** (lom still scores 8.0 vs en 7.0 — the margin rule below is what makes it English) |
| `language vocab` live | `fini` (kq) → 8 real cited entries (koloqua_00005/00062/00063/00064/00065/00162/00778/00779); `one` (bsq) → "dō" (bassa_00001) + Bassa Vah UDHR |
| `language pronounce` live | `dō` (bsq) → "dō (syllables: dō, heuristic), 'one' (bassa_00001)"; `pekin` (kq) → attested "They fini fool we pekin them." (koloqua_00005), syllables heuristic |
| `language route` live | "I de go to the market today." → kq, asr none, fallback moonshine-small, honest "no Koloqua ASR model exists yet" message, confidence 0.43 |
| `language evaluate` (real dataset, limit 100) | **identification 846/1100 = 76.9%** — kq 27%, en-lr 59%, bsq 86%, kpe 100%, vai 84%, grb 85%, kro 77%, lom 69%, mnk 74%, gol 85%, dnj 100%; **code-switch 8/100 boundaries, precision 0.03, recall 0.08** (236 predicted switches) |
| `languageforge validate` live | valid contribution (scope `asr,training`) → "valid contribution: test_00001 [kq]"; scope `research` correctly rejected ("scope must allow asr or training"), exit 1 |
| `talk` (Polyglot text) live | `talk "I de go." --language kq` → Sando answers **"I de go."** (verbatim koloqua_00043); `talk "Hello, how are you?" --language en` → greeting; TTS honestly unavailable in both |
| Live `converse` (Moonshine-Streaming-small, mock brain) | **PROVEN with real speech**: `hello.wav` ("Hello, this is Sando speaking in Liberian English.") → transcribed **exactly**, identified en-lr (confidence 0.25, 2/8 tokens scored), mock brain answered, `asr=ran brain=ran tts=unavailable`; `--language kq` run detects en-lr (the audio IS English) and reports the routing honestly |
| TTS (Qwen3-TTS-0.6B-Q8_0, 1.9 GB) | **Still not runnable on this VM** — guard refuses honestly: "tts skipped: model qwen3-tts-0.6b is 1898 MB but only 384 MB is free" |
| C API language entry points | present: `sando_language_count`, `sando_language_code`, `sando_language_name`, `sando_language_identify` (**26 exports total**, was 22); unit-tested (count 11, code[0]="en-lr", name("kq")="Koloqua", unknown → null) |
| Weights / dataset in git | none — `models/` gitignored; the dataset is read-only outside the repo and only short cited fixture phrases appear in tests |
| audio.cpp version shipped | **0.9.3 prebuilt, NOT 0.9.5** (unchanged — the 0.9.5 source build remains an open follow-up) |

## Phase 4 modules (what landed)

- Vocabulary (`src/vocabulary.zig`): `Dataset` (arena-owned entries,
  `loadJson`/`loadFile`), `Vocabulary` (per-language registry),
  tokenize (apostrophes + tone marks kept), whole-word lookup +
  English→language lookup, lazy word-set for identification. Every
  match carries its dataset id + source for citation.
- Language (`src/language.zig`): 11-language registry (order en-lr,
  kq, bsq, kpe, vai, grb, kro, lom, mnk, gol, dnj), `normalizeCode`
  ("en"→"en-lr", names, "gio"→"dnj"), marker+wordlist identification,
  code-switch detection, `promptFor` (language-aware brain prompts).
- Pronunciation (`src/pronunciation.zig`): attested-form lookup +
  mechanical syllabify, always labelled heuristic.
- AdaptiveEar (`src/adaptive_ear.zig`): ASR routing decisions +
  correction lexicon (hash-map, replace frees the old value, not the
  original key — see the double-free fix below).
- LanguageForge (`src/languageforge.zig`): contribution schema +
  validation + JSON (schema only — no storage backend, no audio
  collected, no recordings).
- Evaluation (`src/evaluate.zig`): identification + code-switch
  evaluator over real labeled examples (first N in file order,
  deterministic; Koloqua = first N attested `response`, English =
  the paired `standard_english`; code-switch = real Koloqua response
  + real English sentence of a different entry, boundary known by
  construction, ±1 word tolerance).
- Wiring: `conversation.zig` renderPrompt adds a language line via
  `lang.promptFor`; `brain.zig` MockBrain gained 5 Koloqua rules with
  VERBATIM dataset replies (cited ids: koloqua_00043/00005/00110/
  00109/00150); `cli.zig` new commands (`language list/identify/
  vocab/pronounce/route/evaluate`, `languageforge validate`, `talk`,
  converse AdaptiveEar routing report); version bump 0.3.0 → 0.4.0.

## Phase 4 measured accuracy — how the numbers moved

All on the same eval (`language evaluate --data-dir <real> --limit
100`, 1,100 examples). Three fixes were made during verification,
each measured before/after:

| Step | Identification | kq | en-lr |
|---|---|---|---|
| Count-based scoring only (baseline) | 72.8% (801/1100) | 13% | 10% |
| + strong-Koloqua-marker rule | 74.1% (815/1100) | 27% | 10% |
| + short-ASCII word rule | 75.5% (831/1100) | 27% | 44% |
| + wordlist-vs-English margin rule | **76.9% (846/1100)** | 27% | 59% |

- **Strong-marker rule** (`language.zig`): a Koloqua marker with
  weight ≥ 2 (de/fini/na/nohn/dor/pekin/ain't/yah/sor/self) decides
  Koloqua outright. Koloqua shares English's lexicon, so count-based
  scoring loses to English common words on most real Koloqua
  sentences ("The Minister them coming." has "the"+"them" against a
  single weak marker). A strong marker is essentially never plain
  English.
- **Short-ASCII rule** (`vocabulary.zig`): 1–2 byte all-ASCII tokens
  do not enter the word set and never match ("a", "is", "to", "na",
  "go" collide across languages and with English). Before it, a plain
  English sentence scored lom=10 on five such collisions. Accented
  short words still count ("dō" is 3 bytes; "à" is non-ASCII). Cost:
  Bassa recall 99% → 86% (some Bassa words are 2 ASCII chars).
- **Margin rule** (`language.zig`): a wordlist language must beat
  English by ≥ 2 points (a full word) to be chosen when English
  scored at all. The wordlists contain English-looking tokens from
  dirty entries (lorma_02152 puts "read book" in the Lorma set;
  lorma_00593, a grammar note, puts "the" there), so a 1-point edge
  is noise. Single-word wordlist examples still win (English 0).

## Phase 4 bugs found during verification (all fixed, all in-tree)

1. **Use-after-free segfault in `Dataset.loadJson`** — the real bug
   behind the first failing runs. `std.json.parseFromSlice` with the
   default `.alloc_if_needed` leaves string slices pointing INTO the
   input `bytes`, which `loadFile` frees on return — every Entry
   dangled (proven by a probe that segfaulted in `tokenize`). Fix:
   `parseFromSliceLeaky` + `.allocate = .alloc_always` (strings
   copied into the Dataset arena) + `.ignore_unknown_fields = true`
   (real files carry region/register/notes/license, which the
   struct does not declare — that was also why the CLI reported
   `InvalidJson` on the real dataset). `voicedna.zig` and
   `languageforge.zig` were checked and are safe (they dupe before
   deinit).
2. **Zig 0.17.1 shadowing** — a parameter named `language` shadows
   the `language` module import (compile error). Fixed by aliasing
   the import to `lang` in `conversation.zig` and `c_api.zig` (and
   renaming a test-local `lang` to `lang_code`).
3. **`std.ArrayList.writer` + `std.json.stringify` do not exist in
   0.17.1** — `languageforge.zig` stringify now uses
   `std.json.Stringify.valueAlloc`; `Language.code`/`name` are
   `[:0]const u8` so the C API can return them as NUL-terminated.
4. **Double free in `CorrectionLexicon.add`** — `fetchPut` returns
   the old key AND value, but the map keeps the ORIGINAL key, so
   freeing `old.key` freed a live key (proven by a panic trace).
   Fix: free the new (unstored) key + the old value.
5. **Code-switch `switches` always 0** — computed from
   `segments.items.len` AFTER `toOwnedSlice` emptied the list.
   Fixed by counting before the move.

## Phase 4 dataset facts (measured, not from the brief)

- Koloqua: **11,780 entries = 10,940 `expansion_*` (pattern-derived)
  + 840 non-expansion (attested)**. The brief said 778 attested;
  the measured count is **840 — a 62-entry discrepancy to note
  honestly** (counted by `types` prefix, 2026-11-15). Attested
  types: dictionary_gloss 594, parallel_sentence 81, song_lyric 35,
  negation 26, tense_aspect_general 14, aspect_habitual 10,
  tense_completive 9, proverb 7, tense_future_proximate 6,
  plural_marking 6, pronouns 6, copula 5, tense_progressive 5,
  tense_past 5, modality 4, tense_perfect 4, tense_future 3,
  copula_absence 2, possession 2, complementizer_say 1,
  copula_locative 1, determiners 1, grammar_example 1,
  preposition 1.
- Attested Koloqua entries are mostly SHORT: **75% are ≤ 3 words**,
  and only **6% carry a strong marker** — that is the ceiling on
  the 27% kq number below, not a bug in the scorer.
- Wordlist languages' first-100 eval examples are not all
  wordlist-type: kpelle/vai/gola/dnj first-100 are
  parallel_sentence/dictionary_gloss/parallel_verse — the word set
  must (and does) include those entry types, which is why dirty
  entries can pollute it (see margin rule).
- Single-word identification is ambiguous across wordlists: "dō"
  scores bsq/vai/grb/kro/lom/mnk 2.0 each; the tie breaks in
  registry order (bsq first). Recorded as a limitation, not fixed.

## Phase 4 honest gaps

1. **Koloqua ASR and TTS cannot run on this VM** — no Koloqua ASR
   model exists and no Koloqua TTS voice exists; the 2 GB Qwen3-TTS
   model cannot load here anyway. `route` and `talk`/`converse`
   say so explicitly (Moonshine-English fallback for ASR, TTS
   unavailable). Koloqua conversation is TEXT ONLY in this phase.
2. **Koloqua identification is 27% on attested entries** (limit
   100) — because 75% of attested entries are ≤ 3-word glosses and
   only 6% carry a strong marker. On full sentences with markers
   the unit tests pass 100% (all real Koloqua sentences tested).
   The evaluator's first-N selection measures glosses, not
   conversation; a sentence-weighted eval set would read higher.
3. **English identification is 59%** (limit 100) — short English
   translations are marker-sparse and often abstain as "und"
   rather than misclassifying (with only the Koloqua vocab loaded,
   the first 100 English translations had 0 wrong-language errors:
   73 right, 27 und). With all wordlists loaded the remaining
   errors are wordlist steals, mostly fixed by the margin rule
   (en 10% → 59% across the three fixes).
4. **Code-switch detection is poor on constructed examples**
   (8/100 boundaries, precision 0.03, recall 0.08, 236 predicted
   switches) — it over-predicts because Koloqua halves contain
   English words that flip the tag. The unit test on a real
   constructed sentence passes; the evaluator's concatenated
   pairs are artificial. Real conversational code-switching needs
   longer runs and a run-length gate (Phase 5 refinement, not
   attempted here).
5. **Dirty dataset entries pollute word sets** (lorma_02152,
   lorma_00593) — mitigated by the margin rule, NOT cleaned: the
   dataset is read-only and is never modified by this project.
6. **LanguageForge is schema-only** — validation + JSON, no storage
   backend, no audio collected, no recordings. The consent rule
   (scope must allow asr or training) is enforced at validation.
7. **No model training** — the engine runs models; Koloqua comes
   from the LoRA fine-tune track, not from this phase.
8. **audio.cpp 0.9.5 not landed** (unchanged).

## Phase 3 STATUS (unchanged record below)

Phase 3 (Intelligence & Conversational AI): **COMPLETE, builder-verified
and VERIFIED INDEPENDENTLY BY D from a clean worktree**, 2026-11-15.
Built and tested on this VM (Intel Xeon Platinum 8321HC, 4 cores,
AVX-512, Ubuntu 24.04, glibc 2.39, Zig 0.17.1). Pushed by D after
verification — origin/main is the Phase 3 head.

## Phase 3 verification summary (D, independent, fresh worktree)

D re-ran everything from a clean worktree with a clean cache: `zig build`
exit 0; test binary direct = **All 91 tests passed, exit 0**; `converse`
single turn live (exact transcription, mock brain answered,
`asr=ran brain=ran tts=unavailable`); barge-in live (reply cut at
"Hello!", interrupt transcribed live, joke delivered, 1 barge-in, 4
history turns); multi-turn live (2 turns, history 4). One builder claim
did NOT reproduce: the SmartCache is in-process only, so a repeat
`converse` run in a fresh process re-runs ASR (`asr=ran`, verified twice
with the same out-dir) — the cache leg is proven in-process by unit
test only, not across processes. Corrected in the table below.

| Check | Result |
|---|---|
| `zig build -j1 -Dcpu=baseline` | clean, exit 0 |
| `zig build test -j1 -Dcpu=baseline`, test binary run directly | **91/91 tests pass** (was 68/68), exit 0, **no leaks** |
| CLI smoke (`version`, `doctor`) | 0.3.0 Phase 3; doctor correct (audio.cpp 0.9.3, 17 tasks, 133 families) |
| Live `converse` (Moonshine-Streaming-small, 287 MB, CPU; mock brain) | **PROVEN with real speech**: "Hello, this is Sando speaking." → transcribed exactly, mock brain answered "Hello! I am Sando. Speak to me and I will answer." (~9.5 s for the whole turn, model load included) |
| Live barge-in (`converse --interrupt`) | **PROVEN**: reply cut short at "Hello!", interrupt transcribed live ("Tell me a joke instead."), follow-up joke delivered, 1 barge-in, 4 history turns |
| Live multi-turn + cache | 2 turns, history grows to 4; SmartCache is in-process only — a repeat `converse` run in a fresh process re-runs ASR (`asr=ran`, D verified twice with the same out-dir), so the cache leg is proven in-process by unit test, not across processes |
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
