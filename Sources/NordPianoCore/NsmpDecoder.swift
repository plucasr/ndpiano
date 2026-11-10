import Foundation

/// Nord Sample (`.nsmp3` / `.nsmp4`, codec 3/4) decoder, a Swift port of OpenNord's
/// `src/lib/clavia/cbin.ts` + `clavia/sample-identify.ts` + `ns4/nsmp-codec.ts` +
/// `ns4/nsmp.ts` (AGPL-3.0). Decode is local-only: factory samples are Clavia's
/// audio — never extract or share them.
///
/// The CBIN envelope (`CBIN` magic, `nsmp` tag, format 1 → record at 0x2C) frames an
/// `NSMP` section tree of 12-byte `[tag:u32][version:u32][size:u32]` headers:
/// `NSMP → hdr (name) → cat → map (zones) → N×stk (strokes) → sty → meta`.
/// Each `stk` payload is a stroke header (global id u32 @+0, root key @+5, replay
/// rate u16 BE @+6, channel count byte @+8, region pointers u32 BE @+0x12/+0x1b/
/// +0x24/+0x2d, loop-decay s24 @+0x28) followed by the NW1 block stream: one 32-bit
/// big-endian header word (`sampleCnt` bits 0–13, order bits 14–17, bitWidth−1 bits
/// 19–22, loopDecay bit 18, linMode bit 23) then order-N binomial-predictor residuals.
/// Codec 4 (`.nsmp4`): per-channel bitstreams interleaved word-by-word, zero-sample
/// blocks are segment markers, stream runs to end of section. Codec 3 (`.nsmp3`):
/// single sample-interleaved bitstream terminated by a stop sentinel (order 0,
/// bitWidth 1). Not ported: codec 1/2 and OG `.nsmp` (NWS/24-bit) generations.

public enum Nsmp {
    /// Gain-envelope updates per second the loop decay is defined against.
    public static let envelopeRate = 21_700
    /// The stroke-header pitch base (0x88ba = 35002 Hz) every real stroke carries at +6.
    public static let sampleRateBase = 0x88ba
    /// Fixed binomial predictor coefficients by order (0–7), newest history first.
    static let predictors: [[Int32]] = [
        [], [1], [2, -1], [3, -3, 1], [4, -6, 4, -1],
        [5, -10, 10, -5, 1], [6, -15, 20, -15, 6, -1], [7, -21, 35, -35, 21, -7, 1],
    ]
    static let historySize = 32
    /// Raw reconstructions of real 16-bit content stay well under this.
    static let bound = 1 << 26
}

public enum NsmpError: Error, CustomStringConvertible {
    case notASample
    case badBlock(String)

    public var description: String {
        switch self {
        case .notASample: return "missing CBIN/NSMP signature"
        case .badBlock(let m): return m
        }
    }
}

// MARK: - Little helpers (big-endian reads, out-of-range → 0 like the TS `?? 0`)

private func byte(_ b: [UInt8], _ at: Int) -> Int {
    (at >= 0 && at < b.count) ? Int(b[at]) : 0
}

private func u16be(_ b: [UInt8], _ at: Int) -> Int {
    byte(b, at) << 8 | byte(b, at + 1)
}

private func u24be(_ b: [UInt8], _ at: Int) -> Int {
    byte(b, at) << 16 | byte(b, at + 1) << 8 | byte(b, at + 2)
}

private func u32be(_ b: [UInt8], _ at: Int) -> UInt32 {
    UInt32(byte(b, at)) << 24 | UInt32(byte(b, at + 1)) << 16
        | UInt32(byte(b, at + 2)) << 8 | UInt32(byte(b, at + 3))
}

private func u16le(_ b: [UInt8], _ at: Int) -> Int {
    byte(b, at) | byte(b, at + 1) << 8
}

private func u32le(_ b: [UInt8], _ at: Int) -> UInt32 {
    UInt32(u16le(b, at) | u16le(b, at + 2) << 16)
}

private func hasCbinMagic(_ b: [UInt8]) -> Bool {
    byte(b, 0) == 0x43 && byte(b, 1) == 0x42 && byte(b, 2) == 0x49 && byte(b, 3) == 0x4e // 'CBIN'
}

/// The 4-char file-type tag at bytes 8–11, trailing NUL/space padding dropped.
private func fileTypeTag(_ b: [UInt8]) -> String {
    var end = min(12, b.count)
    while end > 8 && (b[end - 1] == 0 || b[end - 1] == 0x20) { end -= 1 }
    return String(bytes: b[8..<end], encoding: .ascii) ?? ""
}

// MARK: - Identity (cbin.ts + sample-identify.ts)

public struct NsmpIdentity: Equatable {
    public let recognized: Bool
    /// Library version as shown, e.g. "4.10" (legacy: the raw revision).
    public let version: String?
    /// Codec generation = floor(versionRaw / 100): 3 for `.nsmp3`, 4 for `.nsmp4`.
    public let codec: Int?
    /// OG/legacy `NWS` container (original `.nsmp`) — not decodable here.
    public let legacy: Bool
}

private let nsmpMagic: UInt32 = 0x4e534d50 // "NSMP"

/// Where the section tree starts: `NSMP` root at 0x2C (format 1) or 0x18 (format 0).
func nsmpBodyStart(_ b: [UInt8]) -> Int? {
    if u32be(b, 0x2c) == nsmpMagic { return 0x2c }
    if u32be(b, 0x18) == nsmpMagic { return 0x18 }
    return nil
}

/// Identify a `.nsmp*` file from its header alone (no section decode).
public func identifyNsmp(_ bytes: [UInt8]) -> NsmpIdentity {
    guard hasCbinMagic(bytes), fileTypeTag(bytes) == "nsmp" else {
        return NsmpIdentity(recognized: false, version: nil, codec: nil, legacy: false)
    }
    let legacy: Bool
    if let start = nsmpBodyStart(bytes) {
        legacy = false
        _ = start
    } else {
        // No NSMP root found: fall back to the CBIN version like the TS layout guess.
        let codecGuess = u16le(bytes, 0x14) / 100
        legacy = codecGuess == 1 || codecGuess == 2
    }
    let versionRaw = u16le(bytes, 0x14)
    let undefinedVer = versionRaw == 0xffff
    let major = undefinedVer ? 0 : versionRaw / 100
    let version = legacy
        ? (undefinedVer ? "undefined" : "\(versionRaw)")
        : "\(major).\(String(format: "%02d", versionRaw - major * 100))"
    return NsmpIdentity(recognized: true, version: version,
                        codec: legacy ? nil : major, legacy: legacy)
}

// MARK: - Sections (nsmp.ts parseNsmpSections)

public struct NsmpSection {
    public let tag: String
    public let version: Int
    /// Payload byte size (excludes the 12-byte section header).
    public let size: Int
    /// Byte offset of the payload (section header start + 12).
    public let payloadOffset: Int
    /// Byte offset of the next section.
    public let endOffset: Int
}

private func tagString(_ tag: UInt32) -> String {
    var s = ""
    for i in stride(from: 24, through: 0, by: -8) {
        let c = Int((tag >> UInt32(i)) & 0xff)
        s.append(Character(Unicode.Scalar(c >= 0x20 && c < 0x7f ? c : 0x2e)!)) // '.' for junk
    }
    return s
}

/// Walk the codec-3/4 section tree: 12-byte `[tag:u32][version:u32][size:u32]` headers.
public func parseNsmpSections(_ bytes: [UInt8]) -> [NsmpSection] {
    guard let bodyStart = nsmpBodyStart(bytes) else { return [] }
    var sections: [NsmpSection] = []
    var o = bodyStart
    while o + 12 <= bytes.count {
        let tag = u32be(bytes, o)
        let version = Int(u32be(bytes, o + 4))
        let size = Int(u32be(bytes, o + 8))
        let payloadOffset = o + 12
        if payloadOffset + size > bytes.count { break } // truncated / not a real section
        sections.append(NsmpSection(tag: tagString(tag), version: version, size: size,
                                    payloadOffset: payloadOffset, endOffset: payloadOffset + size))
        o = payloadOffset + size
    }
    return sections
}

/// The printable name from the `hdr` section payload: first printable-ASCII run of length ≥ 2.
public func readNsmpName(_ bytes: [UInt8]) -> String? {
    guard let hdr = parseNsmpSections(bytes).first(where: { $0.tag.hasSuffix("hdr") }) else { return nil }
    var run = ""
    for i in hdr.payloadOffset..<min(hdr.endOffset, bytes.count) {
        let c = bytes[i]
        if c >= 0x20 && c < 0x7f {
            run.append(Character(Unicode.Scalar(c)))
        } else if run.count >= 2 {
            break
        } else {
            run = ""
        }
    }
    let trimmed = run.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - Zones (nsmp.ts readNsmpZones, codec 4 + codec 3 v13/14)

public struct NsmpZone {
    public let rootKey: Int
    public let keyLow: Int
    public let keyHigh: Int
    public let velLow: Int
    public let velTop: Int
    /// Per-zone playback/one-shot flags (+3/+4/+5 of the record).
    public let zoneMode: Int
    public let zonePlayback: Int
    public let zoneIsOneShot: Int
    /// The stroke this zone plays, by the stroke's `stk` header u32 @+0.
    public let globalID: Int
}

/// One 16-byte zone record, root-aligned and identical across codec 3 & 4.
private func readZoneRecord(_ b: [UInt8], _ e: Int) -> NsmpZone {
    NsmpZone(rootKey: byte(b, e), keyLow: byte(b, e + 2), keyHigh: byte(b, e + 1),
             velLow: byte(b, e + 14), velTop: byte(b, e + 15),
             zoneMode: byte(b, e + 3), zonePlayback: byte(b, e + 4), zoneIsOneShot: byte(b, e + 5),
             globalID: Int(u32be(b, e + 8)))
}

/// Codec-4 (map version ≥ 21) zone table: `[6B global][128 × 10B per-note][32B header,
/// last byte = count][count × 16B records][small trailer]`. Falls back to the maximal run
/// of valid records, and walks multi-stroke (velocity-layered) zone heads in between.
private func parseCodec4Zones(_ b: [UInt8], map: NsmpSection, gids: Set<UInt32>) -> [NsmpZone] {
    let rec = 16, perNote = 6 + 128 * 10, header = 32
    let marker: (Int) -> Bool = {
        (byte(b, $0 + 12) == 0 && byte(b, $0 + 13) == 1 && byte(b, $0 + 14) == 0) || byte(b, $0 + 7) == 1
    }
    let idAt: (Int) -> UInt32 = {
        let full = u32be(b, $0 + 8)
        return !gids.contains(full) && gids.contains(UInt32(byte(b, $0 + 11))) ? UInt32(byte(b, $0 + 11)) : full
    }
    let valid: (Int) -> Bool = {
        $0 + rec <= map.endOffset && byte(b, $0) <= 127 && byte(b, $0 + 1) <= 127 && byte(b, $0 + 2) <= 127
            && gids.contains(idAt($0)) && marker($0)
    }
    let recStart = map.payloadOffset + perNote + header
    let count = byte(b, recStart - 1)
    let trailer = map.endOffset - (recStart + count * rec)
    if count >= 1 && trailer >= 0 && trailer <= 8 && valid(recStart) {
        return (0..<count).map { readZoneRecord(b, recStart + $0 * rec) }
    }
    // Multi-stroke zone heads: `[8B head][n × 8B stroke entries]`.
    if count >= 1, let layered = walkMultiStrokeZones(b, start: recStart, count: count,
                                                      end: map.endOffset, gids: gids) {
        return layered
    }
    // Fallback: maximal run of valid 16-byte records; ties break toward the payload end.
    var best = (start: -1, n: 0, trailer: Int.max)
    var p = map.payloadOffset + 6
    while p + rec <= map.endOffset {
        var n = 0
        var o = p
        while valid(o) { n += 1; o += rec }
        if n > 0 {
            let t = map.endOffset - (p + n * rec)
            if n > best.n || (n == best.n && t < best.trailer) { best = (p, n, t) }
        }
        p += 1
    }
    guard best.start >= 0 else { return [] }
    return (0..<best.n).map { readZoneRecord(b, best.start + $0 * rec) }
}

private func walkMultiStrokeZones(_ b: [UInt8], start: Int, count: Int,
                                  end: Int, gids: Set<UInt32>) -> [NsmpZone]? {
    var zones: [NsmpZone] = []
    var o = start
    var layered = false
    for _ in 0..<count {
        guard o + 8 <= end, byte(b, o) <= 127, byte(b, o + 1) <= 127,
              byte(b, o + 2) <= byte(b, o), byte(b, o) <= byte(b, o + 1) else { return nil }
        let n = u16be(b, o + 6)
        guard n >= 1 && n <= 64 && o + 8 + n * 8 <= end else { return nil }
        if n > 1 { layered = true }
        for j in 0..<n {
            let e = o + 8 + j * 8
            let gid = u32be(b, e)
            guard gids.contains(gid) else { return nil }
            zones.append(NsmpZone(rootKey: byte(b, o), keyLow: byte(b, o + 2), keyHigh: byte(b, o + 1),
                                  velLow: byte(b, e + 6), velTop: byte(b, e + 7),
                                  zoneMode: byte(b, o + 3), zonePlayback: byte(b, o + 4),
                                  zoneIsOneShot: byte(b, o + 5), globalID: Int(gid)))
        }
        o += 8 + n * 8
    }
    let trailer = end - o
    return layered && trailer >= 0 && trailer <= 8 ? zones : nil
}

/// The `map` section's per-zone splits/layers table (codec 4 map v21+, codec 3 v13/14 16-byte
/// records). Legacy (`NWS`) and codec-3 `map` v12 tables are not ported.
public func readNsmpZones(_ bytes: [UInt8]) -> [NsmpZone] {
    let sections = parseNsmpSections(bytes)
    guard let map = sections.first(where: { $0.tag.hasSuffix("map") }) else { return [] }
    let stk = sections.filter { $0.tag.hasSuffix("stk") }
    let gids = Set(stk.map { u32be(bytes, $0.payloadOffset) })
    if map.version >= 21 {
        return parseCodec4Zones(bytes, map: map, gids: gids)
    }
    // Codec-3 `map`: [6B global][128 × 6B per-note][1B zone count][N × 16B records][1B pad].
    let recStart = map.payloadOffset + 6 + 128 * 6 + 1
    let count = byte(bytes, recStart - 1)
    return (0..<count)
        .filter { recStart + $0 * 16 + 16 <= map.endOffset }
        .map { readZoneRecord(bytes, recStart + $0 * 16) }
}

// MARK: - Stroke header fields (nsmp.ts)

public struct NsmpStrokeRegions {
    /// Second-start stream offset (editor's SecondStart), in stream words from the stroke start.
    public let secondStart: Int
    /// Loop-begin stream offset, in stream words.
    public let loopBegin: Int
    /// End-of-stream offset (= loop end), in stream words.
    public let end: Int
    public let loops: Bool
    /// Loop-decay field (signed 24-bit @+0x28): −gain·2²³ per envelope update.
    public let decayRaw: Int
}

/// The four region pointers of a `stk` header (u32 BE @+0x12/+0x1b/+0x24/+0x2d) and the
/// loop-decay s24 @+0x28. Nil when the pointers aren't monotonic (unpinned generation).
public func readStrokeRegions(_ b: [UInt8], payloadOffset: Int) -> NsmpStrokeRegions? {
    let u1 = Int(u32be(b, payloadOffset + 0x12))
    let u2 = Int(u32be(b, payloadOffset + 0x1b))
    let u3 = Int(u32be(b, payloadOffset + 0x24))
    let u4 = Int(u32be(b, payloadOffset + 0x2d))
    guard u1 <= u2 && u2 <= u3 && u3 <= u4 else { return nil }
    let span = u4 - u1
    guard span > 0 && span <= (1 << 27) else { return nil }
    let raw = u24be(b, payloadOffset + 0x28)
    return NsmpStrokeRegions(secondStart: u2 - u1, loopBegin: u3 - u1, end: span,
                             loops: u3 != u4, decayRaw: raw >= 0x800000 ? raw - 0x1000000 : raw)
}

/// Loop decay as dB lost per second inside the loop (0 = hold), at Nsmp.envelopeRate.
public func loopDecayDbPerSecond(decayRaw: Int) -> Double {
    let c = Double(abs(decayRaw)) / Double(0x800000)
    guard c > 0 && c < 1 else { return 0 }
    return -20 * log10(c) * Double(Nsmp.envelopeRate)
}

/// A stroke's global id — the u32 that opens its `stk` header (every generation).
public func strokeGlobalId(_ b: [UInt8], payloadOffset: Int) -> UInt32 {
    u32be(b, payloadOffset)
}

/// Channel count from the stroke header (payload byte 8): 1 or 2, else 0 (unknown).
private func strokeChannelHint(_ b: [UInt8], payloadOffset: Int) -> Int {
    let c = byte(b, payloadOffset + 8)
    return c == 1 || c == 2 ? c : 0
}

/// Replay rate u16 BE @+6 (≥ 8000, ≤ 96000), else the 0x88ba = 35002 Hz base.
func strokeSampleRate(_ b: [UInt8], payloadOffset: Int) -> Int {
    let base = u16be(b, payloadOffset + 6)
    return base >= 8000 && base <= 96000 ? base : Nsmp.sampleRateBase
}

// MARK: - Block codec (nsmp-codec.ts)

struct NsmpBlockHeader {
    let sampleCnt: Int
    let filterOrder: Int
    let bitWidth: Int
    let isStop: Bool
    let linMode: Bool
    let loopDecay: Bool
}

private func readBlockHeader(_ word: UInt32) -> NsmpBlockHeader {
    let sampleCnt = Int(word & 0x3fff) // bits 0–13
    let filterOrder = Int((word >> 14) & 0xf) // bits 14–17
    let bitWidth = Int((word >> 19) & 0xf) + 1 // bits 19–22, stored minus one
    return NsmpBlockHeader(sampleCnt: sampleCnt, filterOrder: filterOrder, bitWidth: bitWidth,
                           isStop: filterOrder == 0 && bitWidth == 1,
                           linMode: ((word >> 23) & 1) != 0,
                           loopDecay: ((word >> 18) & 1) != 0)
}

/// One segment-opening (`linMode`) block: its position in stream words and interleaved samples.
public struct NsmpStrokeMark {
    public let word: Int
    public let sample: Int
    public let loopDecay: Bool
}

public struct NsmpDecodedStroke {
    /// Reconstructed PCM per channel — Int16-range Int32 samples (the JS "raw" values).
    public let channels: [[Int32]]
    /// Byte offset just past the stop block (codec 3) / end of the consumed stream (codec 4).
    public let endOffset: Int
    /// Interleaved positions of linMode blocks after position 0.
    public let segments: [Int]
    public let marks: [NsmpStrokeMark]
}

private final class ChannelState {
    var ring = [Int32](repeating: 0, count: Nsmp.historySize)
    var head = 0
    var out: [Int32] = []

    func emit(_ residual: Int32, _ coeff: [Int32], _ order: Int) {
        var pred: Int32 = 0
        for k in 0..<order {
            pred += coeff[k] * ring[(head - 1 - k) & (Nsmp.historySize - 1)]
        }
        let sample = residual &+ pred
        ring[head] = sample
        head = (head + 1) & (Nsmp.historySize - 1)
        out.append(sample)
    }
}

private func signExtend(_ v: Int, bw: Int) -> Int32 {
    v >= 1 << (bw - 1) ? Int32(v - (1 << bw)) : Int32(v)
}

/// Decode one stroke's block stream at `byteOffset`. `wordInterleaved` (codec 4) packs each
/// block's channels as separate 32-bit-word bitstreams interleaved word-by-word and treats
/// zero-sample blocks as segment markers; the default (codec 3) is a single sample-interleaved
/// bitstream terminated by a stop sentinel.
func decodeStroke(_ bytes: [UInt8], byteOffset: Int, channelCount: Int,
                  wordInterleaved: Bool) throws -> NsmpDecodedStroke {
    let channels = (0..<channelCount).map { _ in ChannelState() }
    var o = byteOffset
    var index = 0 // running interleaved sample index (codec 3)
    var cumIL = 0 // running interleaved position (codec 4)
    var segments: [Int] = []
    var marks: [NsmpStrokeMark] = []

    while o + 4 <= bytes.count {
        let hdr = readBlockHeader(u32be(bytes, o))
        if hdr.linMode {
            marks.append(NsmpStrokeMark(word: (o - byteOffset) / 4,
                                        sample: wordInterleaved ? cumIL : index,
                                        loopDecay: hdr.loopDecay))
        }
        o += 4

        if wordInterleaved {
            // Codec 4: zero-sample blocks are segment markers — skip; run to buffer end.
            if hdr.sampleCnt == 0 { continue }
            if hdr.filterOrder > 7 { break }
            if hdr.linMode && cumIL > 0 { segments.append(cumIL) }
            cumIL += hdr.sampleCnt
            let perCh = hdr.sampleCnt / channelCount
            let wordsPerCh = (perCh * hdr.bitWidth + 31) / 32
            guard o + wordsPerCh * channelCount * 4 <= bytes.count else { break }
            let bw = hdr.bitWidth
            let coeff = Nsmp.predictors[hdr.filterOrder]
            for ch in 0..<channelCount {
                // The last channel absorbs any remainder when sampleCnt isn't divisible.
                let count = ch == channelCount - 1 ? hdr.sampleCnt - perCh * (channelCount - 1) : perCh
                var acc: UInt64 = 0
                var nbits = 0
                var produced = 0
                for w in 0..<wordsPerCh {
                    let word = UInt64(u32be(bytes, o + (w * channelCount + ch) * 4))
                    acc |= word << UInt64(32 - nbits)
                    nbits += 32
                    while nbits >= bw && produced < count {
                        let top = Int((acc >> UInt64(64 - bw)) & ((UInt64(1) << UInt64(bw)) - 1))
                        channels[ch].emit(signExtend(top, bw: bw), coeff, hdr.filterOrder)
                        produced += 1
                        acc <<= UInt64(bw)
                        nbits -= bw
                    }
                }
            }
            o += wordsPerCh * channelCount * 4
            continue
        }

        // Codec 3: single sample-interleaved bitstream, stop-terminated.
        if hdr.isStop { break }
        guard hdr.filterOrder <= 7 && hdr.sampleCnt > 0 else {
            throw NsmpError.badBlock("nsmp: invalid block header at \(String(o - 4, radix: 16))")
        }
        if hdr.linMode && index > 0 { segments.append(index) }
        let nWords = (hdr.sampleCnt * hdr.bitWidth + 31) / 32
        guard o + nWords * 4 <= bytes.count else {
            throw NsmpError.badBlock("nsmp: block overruns buffer at \(String(o - 4, radix: 16))")
        }
        var acc: UInt64 = 0
        var nbits = 0
        var produced = 0
        let bw = hdr.bitWidth
        let coeff = Nsmp.predictors[hdr.filterOrder]
        for _ in 0..<nWords {
            acc |= UInt64(u32be(bytes, o)) << UInt64(32 - nbits)
            o += 4
            nbits += 32
            while nbits >= bw && produced < hdr.sampleCnt {
                let top = Int((acc >> UInt64(64 - bw)) & ((UInt64(1) << UInt64(bw)) - 1))
                channels[index % channelCount].emit(signExtend(top, bw: bw), coeff, hdr.filterOrder)
                produced += 1
                index += 1
                acc <<= UInt64(bw)
                nbits -= bw
            }
        }
    }

    return NsmpDecodedStroke(channels: channels.map(\.out), endOffset: o, segments: segments, marks: marks)
}

// MARK: - Loop (nsmp.ts strokeLoop)

public struct NsmpStrokeLoop {
    /// Loop begin, per-channel frames from the stroke start.
    public let loopStart: Int
    /// Loop end (= stroke length), per-channel frames.
    public let loopEnd: Int
    public let loops: Bool
    /// Alternate start point in frames (0 = the normal start).
    public let altStart: Int
    /// dB lost per second inside the loop; 0 = holds its level.
    public let decayDbPerSecond: Double
}

/// The header's stream-word regions looked up in the decoded stream's linMode blocks.
public func strokeLoop(_ regions: NsmpStrokeRegions?, _ decoded: NsmpDecodedStroke,
                       channelCount: Int) -> NsmpStrokeLoop? {
    guard let regions, let last = decoded.marks.last else { return nil }
    let frames = decoded.channels.first?.count ?? 0
    func frameAt(_ word: Int, _ shift: Int) -> Int? {
        decoded.marks.first { $0.word == word + shift }
            .map { Int($0.sample) / max(1, channelCount) }
    }
    // One offset for the whole stroke: anchored on the stream end when it checks out.
    let shift = [last.word - regions.end, 0].first {
        !regions.loops || frameAt(regions.loopBegin, $0) != nil
    }
    guard let shift else { return nil }
    let loopStart = regions.loops ? (frameAt(regions.loopBegin, shift) ?? frames) : frames
    let altStart = frameAt(regions.secondStart, shift) ?? 0
    return NsmpStrokeLoop(loopStart: loopStart, loopEnd: frames,
                          loops: regions.loops && loopStart < frames,
                          altStart: altStart,
                          decayDbPerSecond: regions.loops ? loopDecayDbPerSecond(decayRaw: regions.decayRaw) : 0)
}

// MARK: - Stroke stream location + full decode (nsmp.ts decodeStrokeSection / decodeNsmp)

/// Channel counts to try, hint first.
private func channelOrder(_ hint: Int, _ dflt: [Int]) -> [Int] {
    hint == 1 ? [1, 2] : hint == 2 ? [2, 1] : dflt
}

/// Locate the block stream (header offset 0x60–0x180 in 4-byte steps) and decode it.
/// Codec 4 = word-interleaved, codec 3 = sample-interleaved + stop sentinel.
private func decodeStrokeSection(_ bytes: [UInt8], _ section: NsmpSection,
                                 wordInterleaved: Bool) -> (stroke: NsmpDecodedStroke, channelCount: Int)? {
    let hint = strokeChannelHint(bytes, payloadOffset: section.payloadOffset)
    let bounded = Array(bytes[0..<min(section.endOffset, bytes.count)])
    var hdr = 0x60
    while hdr <= 0x180 {
        let start = section.payloadOffset + hdr
        if start >= section.endOffset { break }
        for channelCount in channelOrder(hint, [1, 2]) {
            guard let result = try? decodeStroke(bounded, byteOffset: start,
                                                 channelCount: channelCount,
                                                 wordInterleaved: wordInterleaved) else { continue }
            let peak = result.channels.first.map { $0.reduce(0) { max($0, abs($1)) } } ?? 0
            let reachedEnd = result.endOffset >= section.endOffset - 8
            if reachedEnd && peak < Nsmp.bound && (result.channels.first?.count ?? 0) > 100 {
                return (result, channelCount)
            }
        }
        hdr += 4
    }
    return nil
}

public struct NsmpStroke {
    /// Index of the source `stk` section in file order.
    public let index: Int
    /// The stroke's global id (`stk` header u32 @+0) — what a zone's `globalID` references.
    public let globalID: UInt32
    /// Channel count the stream was de-interleaved by.
    public let channelCount: Int
    /// Loop window in per-channel frames (end = start + length); nil when not decodable.
    public let loop: (start: Int, length: Int)?
    /// Loop-sustain decay in dB/s, applied Nsmp.envelopeRate times a second inside the loop.
    public let loopDecayDbPerSecond: Double
    /// Replay rate in Hz — the stroke-header pitch base (feed to playback so the sample
    /// sounds at its stored pitch).
    public let sampleRate: Int
}

public struct NsmpDecodedStrokeResult {
    public let stroke: NsmpStroke
    /// Reconstructed PCM per channel (Int16-range Int32 samples).
    public let channels: [[Int32]]
}

/// Decode every `stk` section in a codec-3/4 `.nsmp*` file.
public func decodeNsmpStrokes(_ bytes: [UInt8]) throws -> [NsmpDecodedStrokeResult] {
    let id = identifyNsmp(bytes)
    guard id.recognized, !id.legacy, let codec = id.codec, codec == 3 || codec == 4 else {
        throw NsmpError.notASample
    }
    let wordInterleaved = codec == 4
    var out: [NsmpDecodedStrokeResult] = []
    var index = 0
    for section in parseNsmpSections(bytes) where section.tag.hasSuffix("stk") {
        guard let decoded = decodeStrokeSection(bytes, section, wordInterleaved: wordInterleaved) else {
            index += 1
            continue
        }
        let regions = readStrokeRegions(bytes, payloadOffset: section.payloadOffset)
        let loop = strokeLoop(regions, decoded.stroke, channelCount: decoded.channelCount)
        let loopTuple = loop?.loops == true ? (loop!.loopStart, loop!.loopEnd - loop!.loopStart) : nil
        let meta = NsmpStroke(index: index,
                              globalID: strokeGlobalId(bytes, payloadOffset: section.payloadOffset),
                              channelCount: decoded.channelCount,
                              loop: loopTuple,
                              loopDecayDbPerSecond: loop?.loops == true ? loop!.decayDbPerSecond : 0,
                              sampleRate: strokeSampleRate(bytes, payloadOffset: section.payloadOffset))
        out.append(NsmpDecodedStrokeResult(stroke: meta, channels: decoded.stroke.channels))
        index += 1
    }
    return out
}

// MARK: - Zone selection (zones → strokes)

/// The zone of a `.nsmp*` sample a note plays at a velocity: the zones whose key range
/// covers the note, narrowed by velocity range when a layer covers it (multi-stroke zones
/// come back from `readNsmpZones` as one zone per stroke, sharing the key range but with
/// distinct velocity ranges and stroke ids). Among velocity matches the narrowest range
/// wins — the most specific layer; with no velocity match the widest-velocity zone of the
/// key range plays (the layer table is the authority, velocity ranges may be loose).
public func nsmpZone(for note: Int, velocity: Int, in zones: [NsmpZone]) -> NsmpZone? {
    let byKey = zones.filter { $0.keyLow <= note && note <= $0.keyHigh }
    guard !byKey.isEmpty else { return nil }
    let velMatch = byKey.filter { $0.velLow <= velocity && velocity <= $0.velTop }
    if let best = velMatch.min(by: { ($0.velTop - $0.velLow) < ($1.velTop - $1.velLow) }) {
        return best
    }
    return byKey.max(by: { ($0.velTop - $0.velLow) < ($1.velTop - $1.velLow) })
}
