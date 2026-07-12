// Unit test for the guest page's AudioWorklet resampler: extracts the worklet
// source from guest.html, runs it against a synthetic 440 Hz sine at 48 kHz,
// and checks the emitted 16 kHz PCM is the same tone at 1/3 the sample count.
//
//   node test/worklet.mjs

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const html = readFileSync(
  join(dirname(fileURLToPath(import.meta.url)), "../src/guest.html"),
  "utf8"
);
const match = html.match(/const workletSource = `([\s\S]*?)`;/);
if (!match) {
  console.error("FAIL: could not extract workletSource from guest.html");
  process.exit(1);
}

// Shim the AudioWorklet globals the source expects.
const emitted = [];
const shim = {
  sampleRate: 48000,
  AudioWorkletProcessor: class {
    constructor() {
      this.port = { postMessage: (buf) => emitted.push(new Int16Array(buf)) };
    }
  },
  registered: null,
  registerProcessor(name, cls) {
    this.registered = cls;
  },
};
new Function("sampleRate", "AudioWorkletProcessor", "registerProcessor", match[1])(
  shim.sampleRate,
  shim.AudioWorkletProcessor,
  shim.registerProcessor.bind(shim)
);

const processor = new shim.registered();
const SECONDS = 2;
const FREQ = 440;
const BLOCK = 128; // real AudioWorklet block size
let sent = 0;
for (let block = 0; block < (SECONDS * 48000) / BLOCK; block++) {
  const input = new Float32Array(BLOCK);
  for (let i = 0; i < BLOCK; i++) {
    input[i] = 0.5 * Math.sin((2 * Math.PI * FREQ * (block * BLOCK + i)) / 48000);
  }
  sent += BLOCK;
  processor.process([[input]]);
}

const out = emitted.flatMap((chunk) => Array.from(chunk));
const expected = sent / 3; // 48 kHz → 16 kHz

// 1. Sample count ≈ 1/3 of input (partial tail chunk is unsent — allow one).
if (Math.abs(out.length - expected) > 1700) {
  console.error(`FAIL: got ${out.length} samples, expected ~${expected}`);
  process.exit(1);
}

// 2. Frequency preserved: count zero crossings → f ≈ crossings / (2 * duration).
let crossings = 0;
for (let i = 1; i < out.length; i++) {
  if ((out[i - 1] < 0) !== (out[i] < 0)) crossings++;
}
const duration = out.length / 16000;
const measured = crossings / (2 * duration);
if (Math.abs(measured - FREQ) > 5) {
  console.error(`FAIL: output tone measured ${measured.toFixed(1)} Hz, expected ${FREQ} Hz`);
  process.exit(1);
}

// 3. Amplitude preserved (0.5 float ≈ 16384 peak).
const peak = Math.max(...out.map(Math.abs));
if (peak < 12000 || peak > 17000) {
  console.error(`FAIL: peak amplitude ${peak}, expected ~16384`);
  process.exit(1);
}

// 4. Anti-aliasing: a 10 kHz tone (above the 8 kHz output Nyquist) must be
//    strongly attenuated. Without the low-pass it would alias to a loud
//    phantom 6 kHz tone (~16384 peak) that corrupts recognition.
const aliasEmitted = [];
const aliasProcessor = new shim.registered();
aliasProcessor.port = { postMessage: (buf) => aliasEmitted.push(new Int16Array(buf)) };
for (let block = 0; block < 48000 / BLOCK; block++) {
  const input = new Float32Array(BLOCK);
  for (let i = 0; i < BLOCK; i++) {
    input[i] = 0.5 * Math.sin((2 * Math.PI * 10000 * (block * BLOCK + i)) / 48000);
  }
  aliasProcessor.process([[input]]);
}
// Skip the first 100 ms: the tone's abrupt onset is a broadband click that
// legitimately passes the low-pass; steady state is what matters.
const aliasOut = aliasEmitted.flatMap((chunk) => Array.from(chunk)).slice(1600);
const aliasPeak = Math.max(...aliasOut.map(Math.abs), 0);
if (aliasPeak > 800) {
  console.error(`FAIL: 10 kHz tone leaked through at peak ${aliasPeak} — aliasing not suppressed`);
  process.exit(1);
}

console.log(
  `PASS — ${out.length} samples (expected ~${expected}), tone ${measured.toFixed(1)} Hz, peak ${peak}, 10 kHz alias peak ${aliasPeak}`
);
