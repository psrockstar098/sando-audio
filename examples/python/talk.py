# talk.py — Python example: talk to Sando over the OneAPI.
#
# Start the server first (from the repo root):
#   ./zig-out/bin/sando-audio serve --port 8080
# Then:
#   SANDO_URL=http://127.0.0.1:8080 python3 examples/python/talk.py
# With a key (when the server was started with SANDO_API_KEY set):
#   SANDO_URL=http://127.0.0.1:8080 SANDO_API_KEY=... python3 examples/python/talk.py

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "sdk", "python"))

from sando import SandoClient, SandoError


def main():
    url = os.environ.get("SANDO_URL", "http://127.0.0.1:8080")
    key = os.environ.get("SANDO_API_KEY")
    sando = SandoClient(url, api_key=key)
    try:
        print("health:", sando.health())

        ident = sando.identify("They fini fool we pekin them.")
        print("identify:", ident["language"],
              "(%s, confidence %s)" % (ident["name"], ident["confidence"]))

        conv = sando.create_conversation("en-lr")
        print("conversation:", conv["id"])
        turn = sando.ask(conv["id"], "hello")
        print("you: hello")
        print("sando:", turn["reply"],
              "(asr=%s brain=%s tts=%s)" % (turn["asr"], turn["brain"], turn["tts"]))
        got = sando.get_conversation(conv["id"])
        print("history turns:", len(got["turns"]))
        sando.delete_conversation(conv["id"])
        print("deleted:", conv["id"])

        # VAD over the bundled tone fixture (energy fallback, no model).
        tone_path = os.path.join(os.path.dirname(__file__), "..", "test-tone.wav")
        with open(tone_path, "rb") as f:
            wav = f.read()
        vad = sando.infer_vad(wav)
        print("vad:", vad["source"], "segments:", vad["segments"])

        # TTS honestly reports unavailable on this VM (2 GB model, ~1 GB free).
        try:
            sando.infer_tts("Hello, this is Sando speaking.")
            print("tts: unexpectedly available")
        except SandoError as e:
            print("tts: %s %s — %s" % (e.status, e.code, e.message))

        metrics = sando.metrics()
        print("metrics: total_requests =", metrics["total_requests"])
    except SandoError as e:
        print("SandoError %s %s: %s" % (e.status, e.code, e.message), file=sys.stderr)
        print("Is the server running? Start it with: "
              "./zig-out/bin/sando-audio serve --port 8080", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
