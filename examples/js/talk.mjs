// talk.mjs — JS example: talk to Sando over the OneAPI.
//
// Start the server first (from the repo root):
//   ./zig-out/bin/sando-audio serve --port 8080
// Then:
//   SANDO_URL=http://127.0.0.1:8080 node examples/js/talk.mjs
// With a key (when the server was started with SANDO_API_KEY set):
//   SANDO_URL=http://127.0.0.1:8080 SANDO_API_KEY=... node examples/js/talk.mjs

import { readFile } from "node:fs/promises";
import { SandoClient, SandoError } from "../../sdk/js/sando.mjs";

const url = process.env.SANDO_URL || "http://127.0.0.1:8080";
const key = process.env.SANDO_API_KEY || null;
const sando = new SandoClient(url, key);

try {
  const health = await sando.health();
  console.log("health:", JSON.stringify(health));

  const id = await sando.identify("They fini fool we pekin them.");
  console.log("identify:", id.language, `(${id.name}, confidence ${id.confidence})`);

  const conv = await sando.createConversation("en-lr");
  console.log("conversation:", conv.id);
  const turn = await sando.ask(conv.id, "hello");
  console.log("you: hello");
  console.log("sando:", turn.reply, `(asr=${turn.asr} brain=${turn.brain} tts=${turn.tts})`);
  const got = await sando.getConversation(conv.id);
  console.log("history turns:", got.turns.length);
  await sando.deleteConversation(conv.id);
  console.log("deleted:", conv.id);

  // VAD over the bundled tone fixture (energy fallback, no model).
  const wav = await readFile(new URL("../../examples/test-tone.wav", import.meta.url));
  const vad = await sando.inferVad(wav);
  console.log("vad:", vad.source, "segments:", JSON.stringify(vad.segments));

  // TTS honestly reports unavailable on this VM (2 GB model, ~1 GB free).
  try {
    await sando.inferTts("Hello, this is Sando speaking.");
    console.log("tts: unexpectedly available");
  } catch (err) {
    if (err instanceof SandoError) {
      console.log(`tts: ${err.status} ${err.code} — ${err.message}`);
    } else throw err;
  }

  const metrics = await sando.metrics();
  console.log("metrics: total_requests =", metrics.total_requests);
} catch (err) {
  if (err instanceof SandoError) {
    console.error(`SandoError ${err.status} ${err.code}: ${err.message}`);
  } else {
    console.error(err);
  }
  console.error(`Is the server running? Start it with: ./zig-out/bin/sando-audio serve --port 8080`);
  process.exit(1);
}
