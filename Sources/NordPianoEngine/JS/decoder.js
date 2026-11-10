(() => {
  // opennord-local/src/lib/clavia/cbin.ts
  function hasCbinMagic(bytes) {
    return matchAscii(bytes, 0, "CBIN");
  }
  function fileTypeTag(bytes) {
    let end = Math.min(12, bytes.length);
    while (end > 8 && (bytes[end - 1] === 0 || bytes[end - 1] === 32)) end--;
    return String.fromCharCode(...bytes.slice(8, end));
  }
  function matchAscii(bytes, offset, ascii) {
    for (let i = 0; i < ascii.length; i++) {
      if (bytes[offset + i] !== ascii.charCodeAt(i)) return false;
    }
    return true;
  }

  // opennord-local/src/lib/clavia/crc16.ts
  var CRC16_TABLE = (() => {
    const t = new Uint16Array(256);
    for (let n = 0; n < 256; n++) {
      let crc = n << 8;
      for (let b = 0; b < 8; b++) crc = crc & 32768 ? (crc << 1 ^ 4129) & 65535 : crc << 1 & 65535;
      t[n] = crc;
    }
    return t;
  })();

  // opennord-local/src/lib/clavia/checksum.ts
  var HEADER_SIZE = 44;
  var CHECKSUM_OFFSET = 24;
  var CRC_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) {
        c = c & 1 ? 3988292384 ^ c >>> 1 : c >>> 1;
      }
      t[n] = c;
    }
    return t;
  })();
  function crc32(data, prev = 0) {
    let crc = (prev ^ 4294967295) >>> 0;
    for (let i = 0; i < data.length; i++) {
      crc = CRC_TABLE[(crc ^ data[i]) & 255] ^ crc >>> 8;
    }
    return (crc ^ 4294967295) >>> 0;
  }
  function computeNs4Checksum(bytes) {
    return crc32(bytes.subarray(HEADER_SIZE));
  }
  function verifyNs4Checksum(bytes) {
    if (bytes.length < HEADER_SIZE) return false;
    return storedNs4Checksum(bytes) === computeNs4Checksum(bytes);
  }
  function storedNs4Checksum(bytes) {
    return (bytes[CHECKSUM_OFFSET] | bytes[CHECKSUM_OFFSET + 1] << 8 | bytes[CHECKSUM_OFFSET + 2] << 16 | bytes[CHECKSUM_OFFSET + 3] << 24) >>> 0;
  }

  // opennord-local/src/lib/clavia/sample-identify.ts
  var u32be = (b, o) => (b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3]) >>> 0;
  var u24be = (b, o) => b[o] << 16 | b[o + 1] << 8 | b[o + 2];
  var NSMP_MAGIC = 1314082128;
  var NWS_MAGIC = 5134163;
  function nsmpLayout(bytes) {
    if (u32be(bytes, 44) === NSMP_MAGIC) return { bodyStart: 44, headerSize: 12, legacy: false };
    if (u32be(bytes, 24) === NSMP_MAGIC) return { bodyStart: 24, headerSize: 12, legacy: false };
    if (u24be(bytes, 24) === NWS_MAGIC) return { bodyStart: 24, headerSize: 9, legacy: true };
    const codec = Math.trunc((bytes[20] | bytes[21] << 8) / 100);
    const legacy = codec === 1 || codec === 2;
    return { bodyStart: 44, headerSize: legacy ? 9 : 12, legacy };
  }
  function nsmpHasChecksumField(bytes) {
    const { bodyStart, legacy } = nsmpLayout(bytes);
    return !legacy && bodyStart === 44;
  }
  function identifyNsmp(bytes) {
    if (hasCbinMagic(bytes) && fileTypeTag(bytes) === "npno") {
      return { recognized: true, pianoLibrary: true, legacy: false };
    }
    const recognized = hasCbinMagic(bytes) && fileTypeTag(bytes) === "nsmp";
    if (!recognized) return { recognized: false, legacy: false };
    const { legacy } = nsmpLayout(bytes);
    const versionRaw = bytes[20] | bytes[21] << 8;
    const undefinedVer = versionRaw === 65535;
    const major = undefinedVer ? 0 : Math.trunc(versionRaw / 100);
    const version = legacy ? undefinedVer ? "undefined" : `${versionRaw}` : `${major}.${String(versionRaw - major * 100).padStart(2, "0")}`;
    return { recognized: true, version, versionRaw, codec: major, legacy };
  }

  // opennord-local/src/lib/ns4/nsmp-codec.ts
  var PREDICTOR_COEFF = [
    [],
    [1],
    [2, -1],
    [3, -3, 1],
    [4, -6, 4, -1],
    [5, -10, 10, -5, 1],
    [6, -15, 20, -15, 6, -1],
    [7, -21, 35, -35, 21, -7, 1]
  ];
  var HISTORY_SIZE = 32;
  function readBlockHeader(word) {
    const sampleCnt = word & 16383;
    const filterOrder = word >>> 14 & 15;
    const bitWidth = (word >>> 19 & 15) + 1;
    const isStop = filterOrder === 0 && bitWidth === 1;
    return { sampleCnt, filterOrder, bitWidth, isStop, linMode: !!(word >>> 23 & 1), loopDecay: !!(word >>> 18 & 1) };
  }
  function makeChannels(n) {
    return Array.from({ length: n }, () => ({ ring: new Int32Array(HISTORY_SIZE), head: 0, out: [] }));
  }
  function emit(cs, residual, coeff, order) {
    let pred = 0;
    for (let k = 0; k < order; k++) pred += coeff[k] * cs.ring[cs.head - 1 - k & HISTORY_SIZE - 1];
    const sample = residual + pred;
    cs.ring[cs.head] = sample;
    cs.head = cs.head + 1 & HISTORY_SIZE - 1;
    cs.out.push(sample);
  }
  var signExtend = (v, bw) => v >= 1 << bw - 1 ? v - (1 << bw) : v;
  function decodeStroke(bytes, byteOffset, channelCount, opts = {}) {
    const u32be3 = (o2) => (bytes[o2] << 24 | bytes[o2 + 1] << 16 | bytes[o2 + 2] << 8 | bytes[o2 + 3]) >>> 0;
    const u24be3 = (o2) => (bytes[o2] << 16 | bytes[o2 + 1] << 8 | bytes[o2 + 2]) >>> 0;
    const u24 = opts.u24 === true;
    const hdrBytes = u24 ? 3 : 4;
    const wordBytes = u24 ? 3 : 4;
    const wordBits = u24 ? 24 : 32;
    const readHdr = (o2) => u24 ? u24be3(o2) : u32be3(o2);
    const readWord = (o2) => u24 ? u24be3(o2) << 8 >>> 0 : u32be3(o2);
    const channels = makeChannels(channelCount);
    let o = byteOffset;
    let index = 0;
    let cumIL = 0;
    const segments = [];
    const marks = [];
    while (o + hdrBytes <= bytes.length) {
      const hdr = readBlockHeader(readHdr(o));
      if (hdr.linMode) {
        marks.push({ word: (o - byteOffset) / hdrBytes, sample: opts.wordInterleaved ? cumIL : index, loopDecay: hdr.loopDecay });
      }
      o += hdrBytes;
      if (opts.wordInterleaved) {
        if (hdr.sampleCnt === 0) continue;
        if (hdr.filterOrder > 7) break;
        if (hdr.linMode && cumIL > 0) segments.push(cumIL);
        cumIL += hdr.sampleCnt;
        const perCh = Math.floor(hdr.sampleCnt / channelCount);
        const wordsPerCh = Math.ceil(perCh * hdr.bitWidth / 32);
        if (o + wordsPerCh * channelCount * 4 > bytes.length) break;
        const bw2 = hdr.bitWidth;
        const coeff2 = PREDICTOR_COEFF[hdr.filterOrder];
        for (let ch = 0; ch < channelCount; ch++) {
          const count = ch === channelCount - 1 ? hdr.sampleCnt - perCh * (channelCount - 1) : perCh;
          let acc2 = 0n;
          let nbits2 = 0;
          let produced2 = 0;
          for (let w = 0; w < wordsPerCh; w++) {
            acc2 = (acc2 | BigInt(u32be3(o + (w * channelCount + ch) * 4)) << BigInt(32 - nbits2)) & 0xffffffffffffffffn;
            nbits2 += 32;
            while (nbits2 >= bw2 && produced2 < count) {
              emit(channels[ch], signExtend(Number(acc2 >> BigInt(64 - bw2) & (1n << BigInt(bw2)) - 1n), bw2), coeff2, hdr.filterOrder);
              produced2++;
              acc2 = acc2 << BigInt(bw2) & 0xffffffffffffffffn;
              nbits2 -= bw2;
            }
          }
        }
        o += wordsPerCh * channelCount * 4;
        continue;
      }
      if (hdr.isStop) break;
      if (hdr.filterOrder > 7 || hdr.sampleCnt === 0) {
        throw new Error(`nsmp: invalid block header at 0x${(o - hdrBytes).toString(16)}`);
      }
      if (hdr.linMode && index > 0) segments.push(index);
      const nWords = Math.ceil(hdr.sampleCnt * hdr.bitWidth / wordBits);
      if (o + nWords * wordBytes > bytes.length) {
        throw new Error(`nsmp: block overruns buffer at 0x${(o - hdrBytes).toString(16)}`);
      }
      let acc = 0n;
      let nbits = 0;
      let produced = 0;
      const bw = hdr.bitWidth;
      const coeff = PREDICTOR_COEFF[hdr.filterOrder];
      for (let w = 0; w < nWords; w++) {
        acc = (acc | BigInt(readWord(o)) << BigInt(32 - nbits)) & 0xffffffffffffffffn;
        o += wordBytes;
        nbits += wordBits;
        while (nbits >= bw && produced < hdr.sampleCnt) {
          emit(channels[index % channelCount], signExtend(Number(acc >> BigInt(64 - bw) & (1n << BigInt(bw)) - 1n), bw), coeff, hdr.filterOrder);
          produced++;
          index++;
          acc = acc << BigInt(bw) & 0xffffffffffffffffn;
          nbits -= bw;
        }
      }
    }
    return { channels: channels.map((c) => Int32Array.from(c.out)), endOffset: o, segments, marks };
  }

  // opennord-local/src/lib/ns4/nsmp.ts
  var u32be2 = (b, o) => (b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3]) >>> 0;
  function tagString(tag) {
    let s = "";
    for (let i = 3; i >= 0; i--) {
      const c = tag >>> i * 8 & 255;
      s += c >= 32 && c < 127 ? String.fromCharCode(c) : ".";
    }
    return s;
  }
  var u24be2 = (b, o) => b[o] << 16 | b[o + 1] << 8 | b[o + 2];
  var u16be = (b, o) => b[o] << 8 | b[o + 1];
  function parseNsmpSections(bytes) {
    const { bodyStart, headerSize } = nsmpLayout(bytes);
    const legacy = headerSize === 9;
    const sections = [];
    let o = bodyStart;
    while (o + headerSize <= bytes.length) {
      const tag = legacy ? u24be2(bytes, o) : u32be2(bytes, o);
      const version = legacy ? u16be(bytes, o + 3) : u32be2(bytes, o + 4);
      const size = u32be2(bytes, o + (legacy ? 5 : 8));
      const payloadOffset = o + headerSize;
      if (payloadOffset + size > bytes.length) break;
      sections.push({ tag: tagString(tag), version, size, payloadOffset, endOffset: payloadOffset + size });
      o = payloadOffset + size;
    }
    return sections;
  }
  function readName(bytes, hdr) {
    let run = "";
    for (let i = hdr.payloadOffset; i < hdr.endOffset && i < bytes.length; i++) {
      const c = bytes[i];
      if (c >= 32 && c < 127) run += String.fromCharCode(c);
      else if (run.length >= 2) break;
      else run = "";
    }
    return run.trim() || void 0;
  }
  function readNpnoName(bytes) {
    const NAME_LIKE = /^[A-Za-z0-9][A-Za-z0-9 ._-]*$/;
    let run = "";
    const accept = (s) => {
      const cleaned = s.replace(/[#\s]+$/, "").trim();
      return cleaned.length >= 3 && NAME_LIKE.test(cleaned) ? cleaned : void 0;
    };
    for (let i = 48; i < Math.min(bytes.length, 288); i++) {
      const c = bytes[i];
      if (c >= 32 && c < 127) {
        run += String.fromCharCode(c);
      } else {
        const got = accept(run);
        if (got) return got;
        run = "";
      }
    }
    return accept(run);
  }
  function hdrFactoryFlag(bytes, hdr) {
    const at = hdr.payloadOffset + 8;
    if (at + 1 >= hdr.endOffset || at + 1 >= bytes.length) return false;
    return ((bytes[at] ?? 0) | (bytes[at + 1] ?? 0)) !== 0;
  }
  function readNsmp(bytes) {
    const warnings = [];
    const id = identifyNsmp(bytes);
    if (id.pianoLibrary) {
      const name2 = readNpnoName(bytes);
      return {
        recognized: true,
        pianoLibrary: true,
        legacy: false,
        checksumValid: false,
        name: name2,
        sections: [],
        strokeCount: 0,
        suspectedFactory: true,
        warnings: []
      };
    }
    if (!id.recognized) {
      return { recognized: false, legacy: false, checksumValid: false, sections: [], strokeCount: 0, suspectedFactory: false, warnings: ["Not a Nord Sample file."] };
    }
    const { legacy, version, versionRaw, codec } = id;
    const hasChecksum = nsmpHasChecksumField(bytes);
    const checksumValid = hasChecksum ? verifyNs4Checksum(bytes) : true;
    if (hasChecksum && !checksumValid) warnings.push("Sample checksum mismatch \u2014 possibly truncated/modified.");
    if (legacy && versionRaw !== void 0 && versionRaw !== 8 && versionRaw !== 65535 && codec !== 2) {
      warnings.push(
        `Unverified Nord Sample generation (NWS v${versionRaw}). Only Library 1.x (.nsmp v8), Library 2.0 (codec 2), and the "Undefined" legacy stamp are validated \u2014 readout may be incomplete.`
      );
    }
    const sections = parseNsmpSections(bytes);
    const hdr = sections.find((s) => s.tag === ".hdr" || s.tag.endsWith("hdr"));
    const name = hdr ? readName(bytes, hdr) : void 0;
    const strokeCount = sections.filter((s) => s.tag.endsWith("stk")).length;
    const suspectedFactory = hdr && (codec === 3 || codec === 4) ? hdrFactoryFlag(bytes, hdr) : false;
    return { recognized: true, version, versionRaw, codec, legacy, checksumValid, name, sections, strokeCount, suspectedFactory, warnings };
  }
  var ZONE_LAYOUT = {
    rootKey: 0,
    keyHigh: 1,
    keyLow: 2,
    zoneMode: 3,
    zonePlayback: 4,
    zoneIsOneShot: 5,
    globalID: 11,
    velLow: 14,
    velTop: 15
  };
  var ZONE_LAYOUT_C4 = ZONE_LAYOUT;
  function strokeGlobalId(bytes, payloadOffset) {
    return u32be2(bytes, payloadOffset);
  }
  function readZoneRecord(bytes, e, L) {
    return {
      velTop: bytes[e + L.velTop],
      velLow: bytes[e + L.velLow],
      rootKey: bytes[e + L.rootKey],
      keyHigh: bytes[e + L.keyHigh],
      keyLow: bytes[e + L.keyLow],
      zoneMode: bytes[e + L.zoneMode],
      zonePlayback: bytes[e + L.zonePlayback],
      zoneIsOneShot: bytes[e + L.zoneIsOneShot],
      globalID: u32be2(bytes, e + L.globalID - 3),
      // the u32 at +8; `L.globalID` is its low byte
      recordOffset: e
    };
  }
  function parseCodec4ZoneRecords(bytes, map, strokeCount, gidSet) {
    if (strokeCount <= 0) return [];
    const REC = 16;
    const PER_NOTE = 6 + 128 * 10;
    const HEADER = 32;
    const marker = (o) => bytes[o + 12] === 0 && bytes[o + 13] === 1 && bytes[o + 14] === 0 || bytes[o + 7] === 1;
    const idAt = (o) => {
      const full = u32be2(bytes, o + 8);
      return !gidSet || gidSet.has(full) || !gidSet.has(bytes[o + 11]) ? full : bytes[o + 11];
    };
    const record = (o) => ({ ...readZoneRecord(bytes, o, ZONE_LAYOUT_C4), globalID: idAt(o) });
    const valid = (o) => o + REC <= map.endOffset && bytes[o] <= 127 && bytes[o + 1] <= 127 && bytes[o + 2] <= 127 && (gidSet ? gidSet.has(idAt(o)) : idAt(o) >= 1) && marker(o);
    const recStart = map.payloadOffset + PER_NOTE + HEADER;
    const count = bytes[recStart - 1];
    const trailer = map.endOffset - (recStart + count * REC);
    if (count >= 1 && trailer >= 0 && trailer <= 8 && valid(recStart)) {
      const zones2 = [];
      for (let i = 0; i < count; i++) zones2.push(record(recStart + i * REC));
      return zones2;
    }
    const layered = walkMultiStrokeZones(bytes, recStart, count, map.endOffset, gidSet);
    if (layered) return layered;
    let best = { start: -1, n: 0, trailer: Number.MAX_SAFE_INTEGER };
    for (let p = map.payloadOffset + 6; p + REC <= map.endOffset; p++) {
      let n = 0;
      for (let o = p; valid(o); o += REC) n++;
      if (n === 0) continue;
      const trailer2 = map.endOffset - (p + n * REC);
      if (n > best.n || n === best.n && trailer2 < best.trailer) best = { start: p, n, trailer: trailer2 };
    }
    if (best.start < 0) return [];
    const zones = [];
    for (let i = 0; i < best.n; i++) zones.push(record(best.start + i * REC));
    return zones;
  }
  function walkMultiStrokeZones(bytes, start, count, end, gidSet) {
    if (count < 1) return null;
    const zones = [];
    let o = start;
    let layered = false;
    for (let i = 0; i < count; i++) {
      if (o + 8 > end || bytes[o] > 127 || bytes[o + 1] > 127 || bytes[o + 2] > bytes[o] || bytes[o] > bytes[o + 1]) return null;
      const n = bytes[o + 6] << 8 | bytes[o + 7];
      if (n < 1 || n > 64 || o + 8 + n * 8 > end) return null;
      if (n > 1) layered = true;
      for (let j = 0; j < n; j++) {
        const e = o + 8 + j * 8;
        const globalID = u32be2(bytes, e);
        if (gidSet && !gidSet.has(globalID)) return null;
        zones.push({
          rootKey: bytes[o],
          keyHigh: bytes[o + 1],
          keyLow: bytes[o + 2],
          zoneMode: bytes[o + 3],
          zonePlayback: bytes[o + 4],
          zoneIsOneShot: bytes[o + 5],
          globalID,
          velLow: bytes[e + 6],
          velTop: bytes[e + 7],
          recordOffset: o,
          ...j > 0 ? { strokeEntryOffset: e } : {}
        });
      }
      o += 8 + n * 8;
    }
    const trailer = end - o;
    return layered && trailer >= 0 && trailer <= 8 ? zones : null;
  }
  function strokeRootByGlobalId(bytes, sections) {
    const roots = /* @__PURE__ */ new Map();
    for (const s of sections) {
      if (!s.tag.endsWith("stk")) continue;
      const root = bytes[s.payloadOffset + 5];
      if (root <= 127) roots.set(strokeGlobalId(bytes, s.payloadOffset), root);
    }
    return roots;
  }
  function legacyStrokeRootByGlobalId(bytes, sections) {
    const roots = /* @__PURE__ */ new Map();
    for (const s of sections) {
      if (!s.tag.endsWith("stk")) continue;
      const root = bytes[s.payloadOffset + 5];
      if (root <= 127) roots.set(u32be2(bytes, s.payloadOffset), root);
    }
    return roots;
  }
  var LEGACY_MAP_ROWS = 15;
  var LEGACY_MAP_TABLE = LEGACY_MAP_ROWS + 128 * 6;
  function readNsmpZones(bytes) {
    const sections = parseNsmpSections(bytes);
    const map = sections.find((s) => s.tag.endsWith("map"));
    if (!map) return [];
    if (nsmpLayout(bytes).legacy) {
      if (map.version === 10) {
        return parseCodec2ZoneRecords(bytes, map, strokeRootByGlobalId(bytes, sections));
      }
      const strokeCount = sections.filter((s) => s.tag.endsWith("stk")).length;
      const roots = legacyStrokeRootByGlobalId(bytes, sections);
      const zones2 = parseLegacyZoneRecords(
        bytes,
        map.payloadOffset,
        map.endOffset,
        strokeCount,
        new Set(roots.keys())
      );
      return zones2.map((z) => ({ ...z, rootKey: roots.get(z.globalID) ?? z.rootKey }));
    }
    if (map.version >= 21) {
      const stk = sections.filter((s) => s.tag.endsWith("stk"));
      const gidSet = new Set(stk.map((s) => strokeGlobalId(bytes, s.payloadOffset)));
      return parseCodec4ZoneRecords(bytes, map, stk.length, gidSet);
    }
    if (map.version === 12) {
      return parseCodec3V12ZoneRecords(bytes, map, strokeRootByGlobalId(bytes, sections));
    }
    const recStart = map.payloadOffset + 6 + 128 * 6 + 1;
    const count = bytes[recStart - 1];
    const zones = [];
    for (let i = 0; i < count && recStart + i * 16 + 16 <= map.endOffset; i++) {
      zones.push(readZoneRecord(bytes, recStart + i * 16, ZONE_LAYOUT));
    }
    return zones;
  }
  function parseLegacyZoneRecords(bytes, searchStart, searchEnd, count, gidSet) {
    if (count <= 0) return [];
    const REC = 12;
    const recordsValid = (recStart) => {
      for (let i = 0; i < count; i++) {
        const o = recStart + i * REC;
        if (o + REC > bytes.length || u32be2(bytes, o + 6) > 127) return false;
        if (u16be(bytes, o + 10) !== 1) return false;
        if (gidSet && !gidSet.has(u24be2(bytes, o))) return false;
      }
      return true;
    };
    for (let p = searchEnd - 1; p >= searchStart; p--) {
      if (u16be(bytes, p) !== count) continue;
      const recStart = p + 2;
      if (recStart + count * REC > searchEnd) continue;
      if (!recordsValid(recStart)) continue;
      const raw = Array.from({ length: count }, (_, i) => {
        const o = recStart + i * REC;
        return { globalID: u24be2(bytes, o), keyHigh: u32be2(bytes, o + 6), recordOffset: o };
      });
      raw.sort((a, b) => b.keyHigh - a.keyHigh);
      return raw.map((r, i) => ({
        velTop: 127,
        velLow: 0,
        keyHigh: r.keyHigh,
        // No bottom-key slot: tile from the next zone down; the last zone runs to 0.
        keyLow: i + 1 < raw.length ? raw[i + 1].keyHigh + 1 : 0,
        // No root slot either — `readNsmpZones` overrides this from the `stk` header.
        rootKey: r.keyHigh,
        zoneMode: 0,
        zonePlayback: 0,
        zoneIsOneShot: 0,
        globalID: r.globalID,
        recordOffset: r.recordOffset
      }));
    }
    return [];
  }
  function parseStrokeRefZoneRecords(bytes, map, rootByGid, spec) {
    const gidSet = new Set(rootByGid.keys());
    const { rec, gidOff, keyHighOff } = spec;
    let best = { start: -1, n: 0, trailer: Number.MAX_SAFE_INTEGER };
    for (let start = map.payloadOffset + 6; start + rec <= map.endOffset; start++) {
      let n = 0;
      for (let o = start; o + rec <= map.endOffset && spec.ok(bytes, o, gidSet); o += rec) n++;
      if (n === 0) continue;
      const trailer = map.endOffset - (start + n * rec);
      if (n > best.n || n === best.n && trailer < best.trailer) best = { start, n, trailer };
    }
    if (best.start < 0) return [];
    const raw = [];
    for (let i = 0; i < best.n; i++) {
      const o = best.start + i * rec;
      const globalID = spec.gidBytes === 4 ? u32be2(bytes, o + gidOff) : bytes[o + gidOff];
      raw.push({ globalID, keyHigh: bytes[o + keyHighOff], recordOffset: o });
    }
    return zonesFromStrokeRefs(raw, rootByGid);
  }
  function zonesFromStrokeRefs(raw, rootByGid) {
    raw.sort((a, b) => b.keyHigh - a.keyHigh);
    return raw.map((r, i) => ({
      velTop: 127,
      velLow: 0,
      keyHigh: r.keyHigh,
      keyLow: i + 1 < raw.length ? raw[i + 1].keyHigh + 1 : 0,
      rootKey: rootByGid.get(r.globalID) ?? r.keyHigh,
      zoneMode: 0,
      zonePlayback: 0,
      zoneIsOneShot: 0,
      globalID: r.globalID,
      recordOffset: r.recordOffset
    }));
  }
  function parseCodec2ZoneRecords(bytes, map, rootByGid) {
    const table = map.payloadOffset + LEGACY_MAP_TABLE;
    const count = table + 3 <= map.endOffset ? u24be2(bytes, table) : 0;
    if (count > 0 && table + 3 + count * 15 === map.endOffset) {
      const raw = Array.from({ length: count }, (_, i) => {
        const o = table + 3 + i * 15;
        return { globalID: u24be2(bytes, o), keyHigh: bytes[o + 9], recordOffset: o };
      });
      if (raw.every((r) => r.keyHigh <= 127)) return zonesFromStrokeRefs(raw, rootByGid);
    }
    return parseStrokeRefZoneRecords(bytes, map, rootByGid, {
      rec: 15,
      gidOff: 0,
      keyHighOff: 7,
      ok: (b, o, g) => g.has(b[o]) && b[o + 7] <= 127 && (b[o + 8] === 0 && b[o + 9] === 1 || b[o + 1] === 16 || // Structural marker — but require a real keyHigh (≥ 1): all-zero padding
      // trivially satisfies the zero checks and (when a stroke has gid 0) would
      // otherwise form a giant phantom run of identical zeros.
      b[o + 7] >= 1 && b[o + 4] === 0 && b[o + 5] === 0 && b[o + 6] === 0 && b[o + 8] === 0 && b[o + 10] === 0 && b[o + 11] === 0 && b[o + 12] === 0 && b[o + 13] === 0 && b[o + 14] === 0)
    });
  }
  function parseCodec3V12ZoneRecords(bytes, map, rootByGid) {
    return parseStrokeRefZoneRecords(bytes, map, rootByGid, {
      rec: 11,
      gidOff: 7,
      gidBytes: 4,
      keyHighOff: 3,
      ok: (b, o, g) => b[o] === 0 && b[o + 6] === 1 && b[o + 3] <= 127 && b[o + 3] >= 1 && g.has(u32be2(b, o + 7))
    });
  }
  function readStrokeRegions(bytes, payloadOffset) {
    const u1 = u32be2(bytes, payloadOffset + 18);
    const u2 = u32be2(bytes, payloadOffset + 27);
    const u3 = u32be2(bytes, payloadOffset + 36);
    const u4 = u32be2(bytes, payloadOffset + 45);
    if (!(u1 <= u2 && u2 <= u3 && u3 <= u4)) return null;
    const span = u4 - u1;
    if (span <= 0 || span > 1 << 27) return null;
    const decayRaw = bytes[payloadOffset + 40] << 16 | bytes[payloadOffset + 41] << 8 | bytes[payloadOffset + 42];
    return { secondStart: u2 - u1, loopBegin: u3 - u1, end: span, loops: u3 !== u4, decayRaw };
  }
  var NSMP_ENVELOPE_RATE = 21700;
  function loopDecayDbPerSecond(decayRaw) {
    const c = Math.abs(decayRaw >= 8388608 ? decayRaw - 16777216 : decayRaw) / 8388608;
    if (!(c > 0) || c >= 1) return 0;
    return -20 * Math.log10(c) * NSMP_ENVELOPE_RATE;
  }
  function strokeLoop(regions, decoded, channelCount) {
    const last = decoded.marks[decoded.marks.length - 1];
    if (!regions || !last) return null;
    const frames = decoded.channels[0]?.length ?? 0;
    const frameAt = (word, shift2) => {
      const m = decoded.marks.find((x) => x.word === word + shift2);
      return m ? Math.floor(m.sample / Math.max(1, channelCount)) : null;
    };
    const shift = [last.word - regions.end, 0].find((x) => !regions.loops || frameAt(regions.loopBegin, x) !== null);
    if (shift === void 0) return null;
    const loopStart = regions.loops ? frameAt(regions.loopBegin, shift) : frames;
    const altStart = frameAt(regions.secondStart, shift) ?? 0;
    return {
      loopStart,
      loopEnd: frames,
      loops: regions.loops && loopStart < frames,
      altStart,
      decayDbPerSecond: regions.loops ? loopDecayDbPerSecond(regions.decayRaw) : 0
    };
  }
  var NSMP_SAMPLE_RATE = 35002;
  function strokeSampleRate(bytes, payloadOffset) {
    const base = u16be(bytes, payloadOffset + 6);
    return base >= 8e3 && base <= 96e3 ? base : NSMP_SAMPLE_RATE;
  }
  var BOUND = 1 << 26;
  function strokeChannelHint(bytes, payloadOffset) {
    const c = bytes[payloadOffset + 8];
    return c === 1 || c === 2 ? c : 0;
  }
  function channelOrder(hint, dflt) {
    return hint === 1 ? [1, 2] : hint === 2 ? [2, 1] : dflt;
  }
  var MIN_CHAIN_BLOCKS = 21;
  var MIN_OPENING_CHAIN_BLOCKS = 3;
  function streamReachesEnd(bytes, start, end, u24, minBlocks = MIN_CHAIN_BLOCKS) {
    const hb = u24 ? 3 : 4;
    const wb = u24 ? 24 : 32;
    const tol = u24 ? 3 : 4;
    let o = start;
    let blocks = 0;
    while (o + hb <= end) {
      const w = u24 ? u24be2(bytes, o) : u32be2(bytes, o);
      const sc = w & 16383;
      const fo = w >>> 14 & 15;
      const bw = (w >>> 19 & 15) + 1;
      if (fo === 0 && bw === 1) return blocks >= minBlocks && Math.abs(o + hb - end) <= tol;
      if (fo > 7 || sc === 0) return false;
      o += hb + Math.ceil(sc * bw / wb) * hb;
      blocks++;
    }
    return false;
  }
  function findStrokeStop(bytes, section, u24) {
    return findStrokeStopAt(bytes, section, u24, true) ?? findStrokeStopAt(bytes, section, u24, false);
  }
  var STROKE_FIXED_HEADER = 49;
  function opensStroke(bytes, o, u24) {
    const w = u24 ? u24be2(bytes, o) : u32be2(bytes, o);
    return (w >>> 14 & 15) === 0 && (w >>> 23 & 1) === 1;
  }
  function findStrokeStopAt(bytes, section, u24, openingOnly) {
    const bounded = bytes.subarray(0, section.endOffset);
    const end = section.endOffset;
    const hint = strokeChannelHint(bytes, section.payloadOffset);
    const channels = hint ? [hint] : [2, 1];
    let best = null;
    for (let start = section.payloadOffset + STROKE_FIXED_HEADER; start < section.payloadOffset + 608 && start < end; start++) {
      if (openingOnly && !opensStroke(bytes, start, u24)) continue;
      if (!streamReachesEnd(bytes, start, end, u24, openingOnly ? MIN_OPENING_CHAIN_BLOCKS : MIN_CHAIN_BLOCKS)) continue;
      for (const channelCount of channels) {
        let result;
        try {
          result = decodeStroke(bounded, start, channelCount, { u24 });
        } catch {
          continue;
        }
        if (result.channels[0].length < 100) continue;
        const peak = result.channels[0].reduce((m, x) => Math.max(m, Math.abs(x)), 0);
        if (peak < BOUND && (!best || peak < best.peak)) best = { result, channelCount, peak };
      }
      if (best && best.peak < 1 << 14) break;
    }
    return best ? { result: best.result, channelCount: best.channelCount } : null;
  }
  function decodeStrokeSection(bytes, section, opts) {
    if (opts.u24) return findStrokeStop(bytes, section, true);
    const hint = strokeChannelHint(bytes, section.payloadOffset);
    const bounded = bytes.subarray(0, section.endOffset);
    for (let hdr = 96; hdr <= 384; hdr += 4) {
      const start = section.payloadOffset + hdr;
      if (start >= section.endOffset) break;
      for (const channelCount of channelOrder(hint, [1, 2])) {
        let result;
        try {
          result = decodeStroke(bounded, start, channelCount, { wordInterleaved: opts.wordInterleaved });
        } catch {
          continue;
        }
        const peak = result.channels[0].reduce((m, x) => Math.max(m, Math.abs(x)), 0);
        const reachedEnd = result.endOffset >= section.endOffset - 8;
        if (reachedEnd && peak < BOUND && result.channels[0].length > 100) {
          return { result, channelCount };
        }
      }
    }
    return null;
  }
  function decodeNsmp(bytes) {
    const file = readNsmp(bytes);
    const opts = { wordInterleaved: file.codec === 4, u24: file.legacy };
    const out = [];
    let index = 0;
    for (const section of file.sections) {
      if (!section.tag.endsWith("stk")) continue;
      const decoded = decodeStrokeSection(bytes, section, opts);
      if (decoded) out.push({
        ...decoded.result,
        index,
        channelCount: decoded.channelCount,
        globalID: strokeGlobalId(bytes, section.payloadOffset),
        loop: strokeLoop(readStrokeRegions(bytes, section.payloadOffset), decoded.result, decoded.channelCount),
        sampleRate: strokeSampleRate(bytes, section.payloadOffset)
      });
      index++;
    }
    return out;
  }

  // nordpiano/js/decoder-entry.ts
  function bytesToB64(bytes) {
    const table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let out = "";
    for (let i = 0; i < bytes.length; i += 3) {
      const a = bytes[i], b = i + 1 < bytes.length ? bytes[i + 1] : 0, c = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out += table[a >> 2] + table[(a & 3) << 4 | b >> 4];
      out += i + 1 < bytes.length ? table[(b & 15) << 2 | c >> 6] : "=";
      out += i + 2 < bytes.length ? table[c & 63] : "=";
    }
    return out;
  }
  function b64ToBytes(b64) {
    const table = {};
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (let i = 0; i < chars.length; i++) table[chars[i]] = i;
    const clean = b64.replace(/=+$/, "");
    const out = new Uint8Array(Math.floor(clean.length * 3 / 4));
    let o = 0;
    for (let i = 0; i < clean.length; i += 4) {
      const n = table[clean[i]] << 18 | table[clean[i + 1]] << 12 | (i + 2 < clean.length ? table[clean[i + 2]] : 0) << 6 | (i + 3 < clean.length ? table[clean[i + 3]] : 0);
      if (o < out.length) out[o++] = n >> 16 & 255;
      if (o < out.length) out[o++] = n >> 8 & 255;
      if (o < out.length) out[o++] = n & 255;
    }
    return out;
  }
  function f32ToB64(f) {
    const b = new Uint8Array(f.buffer, f.byteOffset, f.byteLength);
    return bytesToB64(b);
  }
  var files = /* @__PURE__ */ new Map();
  var nextHandle = 1;
  var api = {
    /// Load a sample file (whole bytes, base64). Returns JSON: handle, name, versionRaw, zones.
    loadFile(b64) {
      const bytes = b64ToBytes(b64);
      const handle = nextHandle++;
      files.set(handle, bytes);
      const file = readNsmp(bytes);
      const zones = readNsmpZones(bytes);
      return JSON.stringify({
        handle,
        name: file.name ?? "",
        version: file.version ?? "",
        codec: file.codec ?? 0,
        zones: zones.map((z) => ({ keyLow: z.keyLow, keyHigh: z.keyHigh, rootKey: z.rootKey, velLow: z.velLow, velTop: z.velTop, globalID: z.globalID }))
      });
    },
    /// Decode one stroke to Float32 PCM per channel. Returns JSON with base64 channels.
    decodeStroke(handle, globalID) {
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
          loopStart: s.loop.loopStart,
          loopEnd: s.loop.loopEnd,
          loops: s.loop.loops,
          decayDbPerSecond: s.loop.decayDbPerSecond
        } : null,
        channels: s.channels.map((c) => f32ToB64(Float32Array.from(c)))
      });
    },
    release(handle) {
      files.delete(handle);
    }
  };
  globalThis.NordDecode = api;
})();
