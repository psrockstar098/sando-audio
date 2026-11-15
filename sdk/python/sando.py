# sando.py — Python client for the SANDO Audio OneAPI.
#
# Stdlib only (urllib). No dependencies.
#
#   from sando import SandoClient
#   sando = SandoClient("http://127.0.0.1:8080", api_key=None)
#   conv = sando.create_conversation("en-lr")
#   turn = sando.ask(conv["id"], "hello")
#   print(turn["reply"])
#
# The server is local-first: it binds 127.0.0.1 by default. When a
# SANDO_API_KEY is set on the server, every /v1/* call needs it
# (Authorization: Bearer <key>); without a key the server runs in
# open dev mode. TTS and Koloqua ASR honestly report as unavailable
# on machines that cannot run them — the client surfaces the 503,
# it never fakes a result.

import json
import urllib.error
import urllib.parse
import urllib.request


class SandoError(Exception):
    """An error answer from the OneAPI (or a transport failure)."""

    def __init__(self, status, code, message):
        super().__init__(message or code or "HTTP %s" % status)
        self.status = status
        self.code = code
        self.message = message


class SandoClient:
    def __init__(self, base_url="http://127.0.0.1:8080", api_key=None):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key

    def _headers(self, content_type="application/json"):
        headers = {}
        if content_type:
            headers["Content-Type"] = content_type
        if self.api_key:
            headers["Authorization"] = "Bearer %s" % self.api_key
        return headers

    def request(self, method, path, body=None, raw_body=None, content_type="application/json"):
        url = self.base_url + path
        data = None
        if raw_body is not None:
            data = raw_body
        elif body is not None:
            data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(url, data=data, method=method,
                                     headers=self._headers(content_type))
        try:
            with urllib.request.urlopen(req, timeout=120) as res:
                payload = res.read()
                if res.headers.get_content_type() == "audio/wav":
                    return payload
                return json.loads(payload) if payload else None
        except urllib.error.HTTPError as e:
            payload = e.read()
            try:
                data = json.loads(payload)
                err = data.get("error") or {}
                code = err.get("code") if isinstance(err, dict) else err
                message = err.get("message") if isinstance(err, dict) else None
            except (ValueError, AttributeError):
                code, message = None, payload.decode("utf-8", "replace")
            raise SandoError(e.code, code, message) from None
        except urllib.error.URLError as e:
            raise SandoError(0, "connection_failed", str(e.reason)) from None

    # --- meta ---
    def health(self):
        return self.request("GET", "/v1/health")

    def version(self):
        return self.request("GET", "/v1/version")

    def metrics(self):
        return self.request("GET", "/v1/metrics")

    def models(self):
        return self.request("GET", "/v1/models")

    # --- languages (Phase 4) ---
    def languages(self):
        return self.request("GET", "/v1/languages")

    def identify(self, text):
        return self.request("POST", "/v1/language/identify", {"text": text})

    def vocab(self, word, language="kq"):
        return self.request("POST", "/v1/language/vocab", {"word": word, "language": language})

    def pronounce(self, word, language="kq"):
        return self.request("POST", "/v1/language/pronounce", {"word": word, "language": language})

    def route(self, text):
        return self.request("POST", "/v1/language/route", {"text": text})

    # --- conversations (Phase 3, mock brain only over HTTP) ---
    def create_conversation(self, language="en-lr", voice="v1"):
        return self.request("POST", "/v1/conversation", {"language": language, "voice": voice})

    def list_conversations(self):
        return self.request("GET", "/v1/conversations")

    def get_conversation(self, conv_id):
        return self.request("GET", "/v1/conversation/%s" % urllib.parse.quote(conv_id))

    def ask(self, conv_id, text):
        return self.request("POST", "/v1/conversation/%s/ask" % urllib.parse.quote(conv_id),
                            {"text": text})

    def delete_conversation(self, conv_id):
        return self.request("DELETE", "/v1/conversation/%s" % urllib.parse.quote(conv_id))

    # --- inference (Phase 2) ---
    # wav_bytes: bytes of a WAV file. Returns the ASR result
    # { task, model, text, language, latency_ms }.
    def infer_asr(self, wav_bytes, language="en"):
        path = "/v1/infer?task=asr&language=%s" % urllib.parse.quote(language)
        return self.request("POST", path, raw_body=wav_bytes, content_type="audio/wav")

    # Returns { task: "vad", source: "energy", segments: [...] }.
    def infer_vad(self, wav_bytes):
        return self.request("POST", "/v1/infer?task=vad", raw_body=wav_bytes,
                            content_type="audio/wav")

    # TTS returns raw WAV bytes. Raises SandoError 503 with code
    # "tts_unavailable" when the model does not fit in RAM.
    def infer_tts(self, text, language="en"):
        path = "/v1/infer?task=tts&language=%s" % urllib.parse.quote(language)
        return self.request("POST", path, {"text": text})

    # --- ModelHub (Phase 5) ---
    # Install a model from a local file path ON THE SERVER's machine.
    # The engine never downloads weights.
    def install_model(self, path, name=None, kind="stt"):
        return self.request("POST", "/v1/models/install",
                            {"path": path, "name": name, "kind": kind})

    def remove_model(self, name):
        return self.request("DELETE", "/v1/models/%s" % urllib.parse.quote(name))
