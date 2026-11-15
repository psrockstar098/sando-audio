# SANDO Audio — Deploying the OneAPI Server (Phase 5)

This is a **local development server, not a production deployment**.
There is no TLS, no rate limiting, no request logging, no
persistence, and auth is a single shared key. Do not expose it to
the internet as-is.

## Run it

```sh
# Build (Zig 0.17.1; -Dcpu=baseline keeps the binary portable)
zig build -j1 -Dcpu=baseline

# Config: copy the example and point it at your weights
cp config/sando.example.toml config/sando.toml

# Serve (binds 127.0.0.1 by default; dataset dir is optional)
SANDO_API_KEY=$(head -c 32 /dev/urandom | base64) \
  ./zig-out/bin/sando-audio serve --port 8080 \
  --data-dir ~/workspace/liberia-language-data/datasets
```

Flags: `--config` (default `config/sando.toml`), `--host`
(default `127.0.0.1`), `--port` (default 8080), `--max-sessions`
(default 32), `--data-dir` (language dataset directory).

Without `SANDO_API_KEY` the server starts in open dev mode and
prints a warning. With it, every `/v1/*` call needs
`Authorization: Bearer <key>`. The key is read from the environment
only — never from a flag or a file, and never logged.

## What the server needs

- **Weights** in `models/` (gitignored, never committed): the
  example config lists `moonshine-small` (ASR, 300 MB),
  `qwen3-tts-0.6b` (TTS, 2 GB), `silero-vad` (VAD, not present).
  Install more with `sando-audio models install <file> [--name n]
  [--kind stt|tts|vad]` or `POST /v1/models/install`. The engine
  never downloads weights.
- **RAM**: ASR (Moonshine, 300 MB) runs on this VM (first call
  ~6 s including load, warmed ~1.1 s). TTS (Qwen3-TTS 0.6B, 2 GB)
  does **not** fit in the ~1 GB free on this VM and answers 503
  with the measured numbers. A machine with 4 GB+ free runs it —
  and CI proves TTS on a 16 GB GitHub runner (see README.md,
  Continuous integration).
- **Dataset** (optional): `--data-dir` pointing at the
  `datasets/` folder (one JSON per language) enables `vocab` and
  `pronounce` with real cited entries. Without it those two answer
  `asr_unavailable`; `identify` and `route` still work.

## Smoke test

```sh
curl http://127.0.0.1:8080/v1/health
curl http://127.0.0.1:8080/v1/version
curl -X POST http://127.0.0.1:8080/v1/language/identify \
  -d '{"text":"They fini fool we pekin them."}'
curl -X POST http://127.0.0.1:8080/v1/conversation -d '{"language":"en"}'
# take the id and ask:
curl -X POST http://127.0.0.1:8080/v1/conversation/<id>/ask -d '{"text":"hello"}'
curl http://127.0.0.1:8080/v1/metrics
```

## Limits (by design)

- One request per connection, then close. No keep-alive, no
  WebSocket.
- JSON bodies capped at 64 KiB; WAV bodies at 8 MiB (413 beyond).
- Conversations are in-memory, max 32 by default, oldest evicts.
  A restart forgets them.
- Single-threaded accept loop: one connection at a time. It is a
  dev server, not a load-balanced service.
- The install copy is slow (~33 s for 300 MB on this VM) — a
  streaming copy with no progress reporting.

## If you need more

A production deployment would need, at minimum: TLS termination
(reverse proxy), a real secret store for the key, per-client auth,
rate limiting, request logging, persistent sessions, a job queue,
and a health/readiness split. None of that is in this repo; the
honest next step is a reverse proxy (e.g. Caddy) in front of the
same binary, not more features inside it.
