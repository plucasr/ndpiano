import Foundation

/// Nord Piano (`.npno` / `CNSP`) decoder, a Swift port of OpenNord's
/// `src/lib/ns4/nsp.ts` + `nsp-audio.ts` (AGPL-3.0). Decode is local-only:
/// factory pianos are Clavia's audio — never extract or share them.
///
/// Layout (offsets from the `CNSP` tag — 0x2C in v6 files, 0x18 in v5; big-endian):
///   +0x61C  u16 version, u16 channels (1 | 2), u16 stroke count
///   +0x622  u16[128]: stroke count (velocity layers) of the zone rooted at each MIDI note
///   +0x732  stroke records, 0x76 bytes each
///   blocks  fixed size, 511 words mono / 1022 stereo; word 0: width (bits 0-4),
///           predictor order (bits 5-7), then residuals LSB-first over the 16-bit
///           words, L/R interleaved per frame. The last 64 frames of a block repeat
///           the next block's first 64 (DSP slack) and are skipped.

public enum Nsp {
    public static let sampleRate = 44_100
    public static let envelopeRate = 22_050
    /// A piano's recordings sound this many semitones above their key-map root at 44.1 kHz.
    public static let rootOffset = 4

    static let layerTableOffset = 0x622
    static let recordsOffset = 0x732
    static let recordSize = 0x76
    static let blockOverlap = 64
    /// CNSP format code of v6 files; older (v5) files store floors in 1 dB steps, not 0.2 dB.
    static let cnspV6: UInt16 = 0x464
    /// Binomial predictors by order, newest history sample first.
    static let predictors: [[Int32]] = [[], [1], [2, -1], [3, -3, 1], [4, -6, 4, -1]]
}

public struct NspZone {
    /// The key map's root byte; the recording sounds at `rootNote + Nsp.rootOffset`.
    public let rootNote: Int
    public let lowNote: Int
    public let highNote: Int
}

public struct NspStroke {
    public let index: Int
    /// Key zone, counting from the lowest (`zones` order).
    public let zone: Int
    /// Attenuation floor in 0.2 dB steps, 0 = the hardest hit (v5 files: stored ×5 here).
    public let velocityFrom: Int
    public let flags: Int
    /// A key-release sound (played on note-off), not a dynamic layer.
    public let release: Bool
    public let frames: Int
    /// Byte offset of the first block in the file.
    public let offset: Int
    public let blocks: Int
    /// Predictor history each channel starts from, newest first.
    public let history: [[Int32]]
    /// Sustain loop in frames (`end = start + length`); absent when the stroke doesn't loop.
    public let loop: (start: Int, length: Int)?
    /// Loop-sustain decay, applied `Nsp.envelopeRate` times a second inside the loop.
    public let loopDecay: Double?
}

public struct NspDirectory {
    public let version: Int
    public let channels: Int
    /// Block size in 16-bit words.
    public let blockWords: Int
    public let strokes: [NspStroke]
}

public enum NspError: Error, CustomStringConvertible {
    case notAPiano
    case noDirectory
    case badStroke(String)

    public var description: String {
        switch self {
        case .notAPiano: return "missing CBIN/CNSP signature"
        case .noDirectory: return "no readable CNSP directory"
        case .badStroke(let m): return m
        }
    }
}

/// Offset of the `CNSP` tag, or nil.
public func findCnsp(_ bytes: [UInt8]) -> Int? {
    let lim = min(bytes.count, 0x80)
    guard lim >= 4 else { return nil }
    for i in 0...(lim - 4) where bytes[i] == 0x43 && bytes[i + 1] == 0x4e && bytes[i + 2] == 0x53 && bytes[i + 3] == 0x50 {
        return i
    }
    return nil
}

/// The u16[128] layers-per-root-note table.
public func readLayerTable(_ bytes: [UInt8], base: Int) -> [Int] {
    let at = base + Nsp.layerTableOffset
    guard at + 128 * 2 <= bytes.count else { return Array(repeating: 0, count: 128) }
    return (0..<128).map { n in
        Int(bytes[at + n * 2]) << 8 | Int(bytes[at + n * 2 + 1])
    }
}

private func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
    UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
}

private func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
    UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
}

private func readStroke(_ bytes: [UInt8], at: Int, base: Int, index: Int, channels: Int, floorScale: Int) -> NspStroke {
    // +0x00 u32 first block offset, +0x04 u8 flags, +0x05 u8 attenuation floor,
    // +0x06 u32 frames, +0x0A u16 blocks, +0x0C/+0x14 4×i16 history per channel
    // (oldest first), +0x1C u32 loop start, +0x20 u32 loop length, +0x2E u32 Q23 loop decay.
    let history = [0x0c, 0x14][0..<channels].map { h -> [Int32] in
        [0, 2, 4, 6].map { k in
            let raw = Int32(u16(bytes, at + h + k))
            return raw >= 0x8000 ? raw - 0x10000 : raw
        }.reversed() // newest first
    }
    let loopLength = Int(u32(bytes, at + 0x20))
    let flags = Int(bytes[at + 0x04]) & 3
    let decayRaw = u32(bytes, at + 0x2e)
    return NspStroke(
        index: index,
        zone: 0, // filled in by readNspDirectory
        velocityFrom: Int(bytes[at + 0x05]) * floorScale,
        flags: flags,
        release: flags == 2,
        frames: Int(u32(bytes, at + 0x06)),
        offset: base + Int(u32(bytes, at)),
        blocks: Int(u16(bytes, at + 0x0a)),
        history: history,
        loop: loopLength > 0 ? (Int(u32(bytes, at + 0x1c)), loopLength) : nil,
        loopDecay: loopLength > 0 ? Double(decayRaw) / Double(1 << 23) : nil
    )
}

/// How many key zones the directory's strokes make up.
public func nspZoneCount(_ dir: NspDirectory) -> Int {
    dir.strokes.reduce(0) { max($0, $1.zone + 1) }
}

/// Frames a block of `blockWords` words holds at width `w` (its own, without the overlap).
public func framesPerBlock(blockWords: Int, width: Int, channels: Int) -> Int {
    ((blockWords - 1) * 16) / (width * channels) - Nsp.blockOverlap
}

private func maxFrames(blocks: Int, blockWords: Int, channels: Int) -> Int {
    blocks * framesPerBlock(blockWords: blockWords, width: 1, channels: channels)
}

/// Read the stroke directory; throws when the file has no readable CNSP directory.
public func readNspDirectory(_ bytes: [UInt8]) throws -> NspDirectory {
    guard let base = findCnsp(bytes), base + Nsp.recordsOffset <= bytes.count else { throw NspError.noDirectory }
    let version = u16(bytes, base + 0x61c)
    let channels = Int(u16(bytes, base + 0x61e))
    let count = Int(u16(bytes, base + 0x620))
    guard (channels == 1 || channels == 2), count > 0,
          base + Nsp.recordsOffset + count * Nsp.recordSize <= bytes.count else {
        throw NspError.noDirectory
    }
    let floorScale = version < Nsp.cnspV6 ? 5 : 1
    var raw = (0..<count).map { readStroke(bytes, at: base + Nsp.recordsOffset + $0 * Nsp.recordSize, base: base, index: $0, channels: channels, floorScale: floorScale) }

    // Zone index of each stroke, from the layers-per-root table; fallback: a layer with
    // attenuation floor 0 opens a zone.
    let table = readLayerTable(bytes, base: base)
    let counts = table.filter { $0 > 0 }
    var zones: [Int]
    if counts.reduce(0, +) == count {
        var z = 0
        zones = []
        for c in counts {
            zones.append(contentsOf: Array(repeating: z, count: c))
            z += 1
        }
    } else {
        var z = -1
        zones = raw.map { s in
            if (s.velocityFrom == 0 && !s.release) || z < 0 { z += 1 }
            return z
        }
    }
    for i in raw.indices { raw[i] = NspStroke(index: raw[i].index, zone: zones[i], velocityFrom: raw[i].velocityFrom, flags: raw[i].flags, release: raw[i].release, frames: raw[i].frames, offset: raw[i].offset, blocks: raw[i].blocks, history: raw[i].history, loop: raw[i].loop, loopDecay: raw[i].loopDecay) }

    // Strokes are stored back to back, so the block size falls out of any two neighbours.
    var blockWords = 511 * channels
    if raw.count > 1 && raw[0].blocks > 0 {
        let inferred = (raw[1].offset - raw[0].offset) / raw[0].blocks / 2
        if raw[1].offset > raw[0].offset { blockWords = inferred }
    }
    guard blockWords >= 2 else { throw NspError.noDirectory }
    for s in raw {
        guard s.offset + s.blocks * blockWords * 2 <= bytes.count,
              s.frames <= maxFrames(blocks: s.blocks, blockWords: blockWords, channels: channels) else {
            throw NspError.noDirectory
        }
    }
    return NspDirectory(version: Int(version), channels: channels, blockWords: blockWords, strokes: raw)
}

/// Decode one stroke to integer PCM, one array per channel (44.1 kHz).
public func decodeNspStroke(_ bytes: [UInt8], dir: NspDirectory, stroke: NspStroke) throws -> [[Int32]] {
    let channels = dir.channels
    let blockWords = dir.blockWords
    guard stroke.frames <= maxFrames(blocks: stroke.blocks, blockWords: blockWords, channels: channels) else {
        throw NspError.badStroke("piano stroke \(stroke.index): \(stroke.frames) frames can't fit in \(stroke.blocks) blocks")
    }
    var out = Array(repeating: [Int32](repeating: 0, count: stroke.frames), count: channels)
    var hist = stroke.history
    var t = 0
    for b in 0..<stroke.blocks {
        let at = stroke.offset + b * blockWords * 2
        let header = Int(u16(bytes, at))
        let width = header & 0x1f
        let order = (header >> 5) & 7
        guard width > 0, order < Nsp.predictors.count else {
            throw NspError.badStroke("piano stroke \(stroke.index): bad block header \(String(header, radix: 16)) in block \(b)")
        }
        let coef = Nsp.predictors[order]
        let own = framesPerBlock(blockWords: blockWords, width: width, channels: channels)
        let half = Int32(1 << (width - 1))
        let full = Int32(1 << width)
        var bit = 0 // bit position in the residual area (words 1..)
        for n in 0..<own {
            if t >= stroke.frames {
                throw NspError.badStroke("piano stroke \(stroke.index): more frames than the directory's \(stroke.frames)")
            }
            for c in 0..<channels {
                // `width` bits, LSB-first across consecutive 16-bit words
                var v = 0
                var got = 0
                while got < width {
                    let word = Int(u16(bytes, at + 2 + (bit >> 4) * 2))
                    let offs = bit & 15
                    let take = min(16 - offs, width - got)
                    v += ((word >> offs) & ((1 << take) - 1)) * (1 << got)
                    got += take
                    bit += take
                }
                let r = v >= half ? Int32(v) - full : Int32(v)
                var x = r
                for k in 0..<coef.count { x += coef[k] * hist[c][k] }
                hist[c].removeLast()
                hist[c].insert(x, at: 0)
                out[c][t] = x
            }
            t += 1
        }
    }
    guard t == stroke.frames else {
        throw NspError.badStroke("piano stroke \(stroke.index): decoded \(t) frames, directory says \(stroke.frames)")
    }
    return out
}

/// Velocity (1–127) → attenuation in 0.2 dB units (0 = hardest hit). 40·log10(v/127) law.
public func touchAttenuation(_ velocity: Int) -> Double {
    let v = min(127, max(1, velocity))
    return min(200, max(0, -200 * log10(Double(v) / 127)))
}

/// The stroke a key zone plays at `velocity`, the way the instrument picks it: layers switch
/// halfway between neighbouring floors; no crossfade. `selectOffset` in 0.2 dB steps.
public func strokeFor(_ dir: NspDirectory, zone: Int, velocity: Int, selectOffset: Double = 0) -> NspStroke? {
    let att = touchAttenuation(velocity) + selectOffset
    let layers = dir.strokes.filter { $0.zone == zone && $0.flags == 0 } // loudest first
    guard var pick = layers.first else { return nil }
    for i in 1..<layers.count {
        let floor = Double(layers[i].velocityFrom)
        let prev = Double(layers[i - 1].velocityFrom)
        if floor - Double(Int(floor - prev) / 2) <= att { pick = layers[i] }
    }
    return pick
}

// MARK: - Key map (nsp.ts)

private let keymapOffset = 0x8c
private let keymapLen = 128

/// Decode the per-note key map (CNSP+0x8C, 128 bytes): each byte is the root note of the
/// sample assigned to that MIDI key; 0xFF and 0x00 mark unused keys.
public func readNspZones(_ bytes: [UInt8]) -> [NspZone] {
    guard let cnsp = findCnsp(bytes) else { return [] }
    let at = cnsp + keymapOffset
    guard at + keymapLen <= bytes.count else { return [] }
    var span: [Int: (Int, Int)] = [:]
    for note in 0..<keymapLen {
        let r = Int(bytes[at + note])
        if r == 0 || r == 0xff || r > 127 { continue }
        if let e = span[r] {
            span[r] = (min(note, e.0), max(note, e.1))
        } else {
            span[r] = (note, note)
        }
    }
    guard !span.isEmpty else { return [] }
    let table = readLayerTable(bytes, base: cnsp)
    let layerEnd = Nsp.layerTableOffset + 128 * 2
    if span.count == 1 {
        let root = span.keys.first!
        // A single zone counts only when the layer table agrees (strokes at that root only).
        guard cnsp + layerEnd <= bytes.count else { return [] }
        let agrees = (0..<128).allSatisfy { note in (note == root) == (table[note] > 0) }
        guard agrees else { return [] }
    }
    return span
        .map { NspZone(rootNote: $0.key, lowNote: $0.value.0, highNote: $0.value.1) }
        .sorted { $0.lowNote < $1.lowNote }
}

/// The key zone `midi` plays and the re-pitch from its recording, in semitones; nil when no
/// zone covers the key.
public func pianoKey(_ zones: [NspZone], midi: Int) -> (zone: Int, semitones: Double)? {
    guard let idx = zones.firstIndex(where: { $0.lowNote <= midi && midi <= $0.highNote }) else { return nil }
    return (idx, Double(midi - zones[idx].rootNote - Nsp.rootOffset))
}

// MARK: - Identity (name, variant, version) — nsp.ts readNspIdentity

public struct NspIdentity: Equatable {
    public let name: String?
    public let variant: String?
    public let version: String
}

/// Who a piano file says it is — name/variant from the metadata block (CNSP+0x16,
/// `name#variant` space-padded), version from the CBIN header u16 at 0x14 ("6.10").
public func readNspIdentity(_ bytes: [UInt8]) -> NspIdentity? {
    guard let cnsp = findCnsp(bytes), bytes.count > 0x16 else { return nil }
    // Version u16 at 0x14 is little-endian (0x026C = 620 → "6.20").
    let versionRaw = Int(bytes[0x14]) | Int(bytes[0x15]) << 8
    let major = versionRaw / 100
    let version = "\(major).\(String(format: "%02d", versionRaw - major * 100))"
    // First printable-ASCII run of length ≥ 3 in the 103-byte metadata block,
    // returned whole (TS: run ends at the first non-printable byte).
    var run = ""
    var found: String?
    let from = cnsp + 0x16, to = min(from + 0x67, bytes.count)
    for i in from..<to {
        let c = bytes[i]
        if c >= 0x20 && c < 0x7f {
            run.append(Character(Unicode.Scalar(c)))
        } else {
            if run.count >= 3 { found = run; break }
            run = ""
        }
    }
    if found == nil && run.count >= 3 { found = run }
    let full = found?.trimmingCharacters(in: .whitespaces)
    let hash = full?.firstIndex(of: "#")
    let name = hash.map { String(full![..<$0]).trimmingCharacters(in: .whitespaces) } ?? full
    let variant = hash.map { String(full![full!.index(after: $0)...]).trimmingCharacters(in: .whitespaces) }
    return NspIdentity(name: name?.isEmpty == true ? nil : name,
                       variant: variant?.isEmpty == true ? nil : variant,
                       version: version)
}
