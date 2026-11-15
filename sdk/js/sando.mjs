// sando.mjs — JavaScript/TypeScript client for the SANDO Audio OneAPI.
//
// Stdlib only (global fetch, Node 18+ / browsers). No dependencies.
//
//   import { SandoClient } from "./sdk/js/sando.mjs";
//   const sando = new SandoClient("http://127.0.0.1:8080", process.env.SANDO_API_KEY);
//   const conv = await sando.createConversation("en-lr");
//   const turn = await sando.ask(conv.id, "hello");
//   console.log(turn.reply);
//
// The server is local-first: it binds 127.0.0.1 by default. When a
// SANDO_API_KEY is set on the server, every /v1/* call needs it
// (Authorization: Bearer <key>); without a key the server runs in
// open dev mode. TTS and Koloqua ASR honestly report as unavailable
// on machines that cannot run them — the client surfaces the 503,
// it never fakes a result.

export class SandoError extends Error {
  constructor(status, code, message) {
    super(message || code || `HTTP ${status}`);
    this.name = "SandoError";
    this.status = status;
    this.code = code;
  }
}

export class SandoClient {
  constructor(baseUrl = "http://127.0.0.1:8080", apiKey = null) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.apiKey = apiKey || null;
  }

  headers(json = true) {
    const h = {};
    if (json) h["Content-Type"] = "application/json";
    if (this.apiKey) h["Authorization"] = `Bearer ${this.apiKey}`;
    return h;
  }

  async request(method, path, body = undefined, { rawBody = null, contentType = null } = {}) {
    const opts = { method, headers: this.headers(contentType !== "audio/wav") };
    if (rawBody !== null) {
      opts.body = rawBody;
      opts.headers["Content-Type"] = contentType || "application/octet-stream";
    } else if (body !== undefined) {
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(`${this.baseUrl}${path}`, opts);
    const text = await res.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = text;
    }
    if (!res.ok) {
      const errObj = data && typeof data === "object" ? data.error : null;
      const code = errObj && typeof errObj === "object" ? errObj.code : errObj;
      const msg = errObj && typeof errObj === "object" ? errObj.message : text;
      throw new SandoError(res.status, code, msg);
    }
    return data;
  }

  async rawRequest(method, path, body, contentType) {
    const res = await fetch(`${this.baseUrl}${path}`, {
      method,
      headers: this.headers(false),
      body,
    });
    if (!res.ok) {
      const text = await res.text();
      let data = null;
      try {
        data = JSON.parse(text);
      } catch {
        data = null;
      }
      const errObj = data && typeof data === "object" ? data.error : null;
      const code = errObj && typeof errObj === "object" ? errObj.code : errObj;
      const msg = errObj && typeof errObj === "object" ? errObj.message : text;
      throw new SandoError(res.status, code, msg);
    }
    return res;
  }

  // --- meta ---
  health() {
    return this.request("GET", "/v1/health");
  }
  version() {
    return this.request("GET", "/v1/version");
  }
  metrics() {
    return this.request("GET", "/v1/metrics");
  }
  models() {
    return this.request("GET", "/v1/models");
  }

  // --- languages (Phase 4) ---
  languages() {
    return this.request("GET", "/v1/languages");
  }
  identify(text) {
    return this.request("POST", "/v1/language/identify", { text });
  }
  vocab(word, language = "kq") {
    return this.request("POST", "/v1/language/vocab", { word, language });
  }
  pronounce(word, language = "kq") {
    return this.request("POST", "/v1/language/pronounce", { word, language });
  }
  route(text) {
    return this.request("POST", "/v1/language/route", { text });
  }

  // --- conversations (Phase 3, mock brain only over HTTP) ---
  createConversation(language = "en-lr", voice = "v1") {
    return this.request("POST", "/v1/conversation", { language, voice });
  }
  listConversations() {
    return this.request("GET", "/v1/conversations");
  }
  getConversation(id) {
    return this.request("GET", `/v1/conversation/${encodeURIComponent(id)}`);
  }
  ask(id, text) {
    return this.request("POST", `/v1/conversation/${encodeURIComponent(id)}/ask`, { text });
  }
  deleteConversation(id) {
    return this.request("DELETE", `/v1/conversation/${encodeURIComponent(id)}`);
  }

  // --- inference (Phase 2) ---
  // wavBytes: Uint8Array/ArrayBuffer of a WAV file. Returns the ASR
  // result { task, model, text, language, latency_ms }.
  async inferAsr(wavBytes, language = "en") {
    return this.request("POST", `/v1/infer?task=asr&language=${encodeURIComponent(language)}`, undefined, {
      rawBody: wavBytes,
      contentType: "audio/wav",
    });
  }
  // Returns { task: "vad", source: "energy", segments: [...] }.
  async inferVad(wavBytes) {
    return this.request("POST", "/v1/infer?task=vad", undefined, {
      rawBody: wavBytes,
      contentType: "audio/wav",
    });
  }
  // TTS returns raw WAV bytes (a Response). Throws SandoError 503
  // with code "tts_unavailable" when the model does not fit in RAM.
  async inferTts(text, language = "en") {
    const res = await this.rawRequest(
      "POST",
      `/v1/infer?task=tts&language=${encodeURIComponent(language)}`,
      JSON.stringify({ text }),
      "application/json",
    );
    return res.arrayBuffer();
  }

  // --- ModelHub (Phase 5) ---
  // Install a model from a local file path ON THE SERVER's machine.
  // The engine never downloads weights.
  installModel(path, name = null, kind = "stt") {
    return this.request("POST", "/v1/models/install", { path, name, kind });
  }
  removeModel(name) {
    return this.request("DELETE", `/v1/models/${encodeURIComponent(name)}`);
  }
}
