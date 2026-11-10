// Embedded decoder entry: exposes OpenNord's nsmp decode stack to Swift via JavaScriptCore.
// Bundled with esbuild into a single script (Sources/NordPianoEngine/JS/decoder.js).
// Pure-JS base64 (no Buffer/atob assumptions in the JSC environment).
import { decodeNsmp, readNsmpZones, readNsmp } from '@/lib/ns4/nsmp';

function bytesToB64(bytes: Uint8Array): string {
  const table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i], b = i + 1 < bytes.length ? bytes[i + 1] : 0, c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += table[a >> 2] + table[((a & 3) << 4) | (b >> 4)];
    out += i + 1 < bytes.length ? table[((b & 15) << 2) | (c >> 6)] : '=';
    out += i + 2 < bytes.length ? table[c & 63] : '=';
  }
  return out;
}

function b64ToBytes(b64: string): Uint8Array {
  const table: Record<string, number> = {};
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  for (let i = 0; i < chars.length; i++) table[chars[i]] = i;
  const clean = b64.replace(/=+$/, '');
  const out = new Uint8Array(Math.floor(clean.length * 3 / 4));
  let o = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const n = (table[clean[i]] << 18) | (table[clean[i + 1]] << 12)
      | ((i + 2 < clean.length ? table[clean[i + 2]] : 0) << 6)
      | (i + 3 < clean.length ? table[clean[i + 3]] : 0);
    if (o < out.length) out[o++] = (n >> 16) & 0xff;
    if (o < out.length) out[o++] = (n >> 8) & 0xff;
    if (o < out.length) out[o++] = n & 0xff;
  }
  return out;
}

function f32ToB64(f: Float32Array): string {
  const b = new Uint8Array(f.buffer, f.byteOffset, f.byteLength);
  return bytesToB64(b);
}

const files = new Map<number, Uint8Array>();
let nextHandle = 1;

const api = {
  /// Load a sample file (whole bytes, base64). Returns JSON: handle, name, versionRaw, zones.
  loadFile(b64: string): string {
    const bytes = b64ToBytes(b64);
    const handle = nextHandle++;
    files.set(handle, bytes);
    const file = readNsmp(bytes);
    const zones = readNsmpZones(bytes);
    return JSON.stringify({
      handle, name: file.name ?? '', version: file.version ?? '', codec: file.codec ?? 0,
      zones: zones.map((z) => ({ keyLow: z.keyLow, keyHigh: z.keyHigh, rootKey: z.rootKey, velLow: z.velLow, velTop: z.velTop, globalID: z.globalID })),
    });
  },
  /// Decode one stroke to Float32 PCM per channel. Returns JSON with base64 channels.
  decodeStroke(handle: number, globalID: number): string | null {
    const bytes = files.get(handle);
    if (!bytes) return null;
    const strokes = decodeNsmp(bytes);
    const s = strokes.find((x) => x.globalID === globalID);
    if (!s) return null;
    return JSON.stringify({
      globalID: s.globalID,
      channelCount: s.channelCount,
      sampleRate: s.sampleRate,
      frames: s.channels[0]?.length ?? 0,
      loop: s.loop ? {
        loopStart: s.loop.loopStart, loopEnd: s.loop.loopEnd, loops: s.loop.loops,
        decayDbPerSecond: s.loop.decayDbPerSecond,
      } : null,
      channels: s.channels.map((c) => f32ToB64(Float32Array.from(c as ArrayLike<number>))),
    });
  },
  release(handle: number) { files.delete(handle); },
};

(globalThis as unknown as Record<string, unknown>).NordDecode = api;
