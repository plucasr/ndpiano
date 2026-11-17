import Foundation

/// SFZ region loop behavior (the `loop_mode` opcode).
public enum SfzLoopMode: String {
    case noLoop = "no_loop"
    case oneShot = "one_shot"
    case continuous = "loop_continuous"
    case sustain = "loop_sustain"
}

/// One playable region of an SFZ program: a sample file plus its key/velocity
/// range, root key and loop points. Defaults follow the SFZ 1.0 spec.
public struct SfzRegion: Equatable {
    /// Sample path as written in the file, relative to the .sfz's directory
    /// (default_path already prepended).
    public var sample: String
    public var loKey = 0
    public var hiKey = 127
    public var loVel = 0
    public var hiVel = 127
    /// `pitch_keycenter`: the note the sample plays unpitched-shifted.
    public var rootKey = 60
    /// Fine tuning in cents (`tune` opcode).
    public var tuneCents = 0
    /// Gain in dB (`volume` opcode, 0 = unity).
    public var volumeDb: Double = 0
    /// Velocity tracking percent (`amp_veltrack`, 100 = full). Organs use 0 —
    /// a tonewheel doesn't care how hard you hit the key.
    public var ampVelTrack: Double = 100
    public var loopMode: SfzLoopMode = .continuous
    /// Explicit loop points in frames (nil = use the WAV's smpl chunk, if any).
    public var loopStart: Int?
    public var loopEnd: Int? // inclusive, per the SFZ spec
    /// CC gate (`loccN`/`hiccN`): the region only sounds while controller N's
    /// value is in this range. How drawbar organs switch partials in and out.
    public var gateCC: Int?
    public var gateLo = 0
    public var gateHi = 127
    /// Release-triggered regions are skipped at parse time (no support yet).
    public var oneShot: Bool { loopMode == .oneShot }

    public func matches(note: Int, velocity: Int) -> Bool {
        (loKey...hiKey).contains(note) && (loVel...hiVel).contains(velocity)
    }

    /// Gate check against a controller value (0…127).
    public func gatePasses(ccValue: Int) -> Bool {
        (gateLo...gateHi).contains(ccValue)
    }
}

/// A parsed .sfz file: a flat list of regions (group/global opcodes already
/// merged down into each region), plus the <control> section's CC defaults.
public struct SfzProgram: Equatable {
    public var regions: [SfzRegion]
    /// `set_ccN` values from <control> (0…127) — initial controller state,
    /// e.g. an organ's default drawbar positions.
    public var controlDefaults: [Int: Int] = [:]
}

public enum SfzError: Error, Equatable {
    case noRegions
}

/// SFZ 1.0 subset parser. Handles <global>/<group>/<region> inheritance,
/// // comments, note names ("c#4", "db3", c4 = 60), and sample paths with
/// spaces (a value runs until the next opcode or header, not the next blank).
public enum SfzParser {

    /// Parse a .sfz file from disk, expanding `#include "path"` directives (each
    /// include's text is inlined in place; paths resolve against the including
    /// file's directory, 4 levels deep max). Sample paths stay relative to the
    /// TOP-LEVEL file, matching how sforzando resolves them.
    public static func parseFile(_ url: URL, depth: Int = 0) -> SfzProgram {
        guard depth < 4,
              var text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            return SfzProgram(regions: [])
        }
        let includePattern = #"(?m)^\s*#include\s+"([^"]+)""#
        while let range = text.range(of: includePattern, options: .regularExpression) {
            let match = String(text[range])
            guard let pathRange = match.range(of: #""([^"]+)""#, options: .regularExpression) else { break }
            let relative = String(match[pathRange].dropFirst().dropLast())
                .replacingOccurrences(of: "\\", with: "/")
            let includeURL = url.deletingLastPathComponent().appendingPathComponent(relative)
            // Parse the include at the next depth, then re-emit its regions as
            // inline <region> blocks (a nested parse loses nothing: the files
            // only carry global/group/region opcodes).
            let included = parseFile(includeURL, depth: depth + 1)
            if included.regions.isEmpty {
                text.removeSubrange(range) // unreadable include: drop it
            } else {
                var inline = ""
                for r in included.regions {
                    inline += "\n<region> sample=\(r.sample) lokey=\(r.loKey) hikey=\(r.hiKey)"
                        + " lovel=\(r.loVel) hivel=\(r.hiVel) pitch_keycenter=\(r.rootKey)"
                        + " tune=\(r.tuneCents) volume=\(r.volumeDb) loop_mode=\(r.loopMode.rawValue)"
                    if let s = r.loopStart { inline += " loop_start=\(s)" }
                    if let e = r.loopEnd { inline += " loop_end=\(e)" }
                    if r.ampVelTrack != 100 { inline += " amp_veltrack=\(r.ampVelTrack)" }
                    if let cc = r.gateCC { inline += " locc\(cc)=\(r.gateLo) hicc\(cc)=\(r.gateHi)" }
                    inline += "\n"
                }
                if !included.controlDefaults.isEmpty {
                    inline += "\n<control>\n"
                    for (cc, v) in included.controlDefaults.sorted(by: { $0.key < $1.key }) {
                        inline += "set_cc\(cc)=\(v)\n"
                    }
                }
                text.replaceSubrange(range, with: inline)
            }
        }
        return parse(text)
    }

    public static func parse(_ text: String) -> SfzProgram {
        // Strip // comments (sample paths use backslashes or plain slashes; a
        // "//" sequence is not meaningful in SFZ paths).
        let cleaned = text.components(separatedBy: .newlines).map { line -> String in
            guard let range = line.range(of: "//"),
                  line[..<range.lowerBound].last?.isWhitespace ?? true else { return line }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")

        var global: [String: String] = [:]
        var group: [String: String] = [:]
        var control: [String: String] = [:] // <control> scope (set_ccN, labels)
        var lastHeader = ""
        var regions: [SfzRegion] = []
        var pending: [String: String] = [:]
        var inRegion = false

        func flushRegion() {
            guard inRegion else { return }
            let merged = global.merging(group) { _, g in g }.merging(pending) { _, r in r }
            if merged["trigger"] == "release" { inRegion = false; pending = [:]; return } // unsupported
            guard var sample = merged["sample"], !sample.isEmpty else {
                inRegion = false; pending = [:]; return
            }
            if let prefix = merged["default_path"], !prefix.isEmpty {
                let sep = prefix.hasSuffix("/") || prefix.hasSuffix("\\") ? "" : "/"
                sample = prefix + sep + sample
            }
            var region = SfzRegion(sample: sample)
            if let key = merged["key"].flatMap(sfzKeyNumber) {
                region.loKey = key; region.hiKey = key; region.rootKey = key
            }
            if let v = merged["lokey"].flatMap(sfzKeyNumber) { region.loKey = v }
            if let v = merged["hikey"].flatMap(sfzKeyNumber) { region.hiKey = v }
            if let v = merged["lovel"].flatMap(Int.init) { region.loVel = v }
            if let v = merged["hivel"].flatMap(Int.init) { region.hiVel = v }
            if let v = merged["pitch_keycenter"].flatMap(sfzKeyNumber) { region.rootKey = v }
            if let v = merged["tune"].flatMap(Int.init) { region.tuneCents = v }
            if let v = merged["volume"].flatMap(Double.init) { region.volumeDb = v }
            if let v = merged["amp_veltrack"].flatMap(Double.init) { region.ampVelTrack = v }
            if let v = merged["loop_mode"].flatMap(SfzLoopMode.init) { region.loopMode = v }
            if let v = merged["loop_start"].flatMap(Int.init) { region.loopStart = v }
            if let v = merged["loop_end"].flatMap(Int.init) { region.loopEnd = v }
            // CC gates: loccN/hiccN pairs (drawbar organs switch partials with these).
            for (key, value) in merged {
                guard let lo = key.range(of: #"^locc(\d+)$"#, options: .regularExpression),
                      let cc = Int(key[lo].dropFirst(4)), let loVal = Int(value) else { continue }
                let hiVal = merged["hicc\(cc)"].flatMap(Int.init) ?? 127
                region.gateCC = cc
                region.gateLo = loVal
                region.gateHi = hiVal
            }
            regions.append(region)
            inRegion = false
            pending = [:]
        }

        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            if cleaned[i] == "<" {
                flushRegion()
                guard let close = cleaned[i...].firstIndex(of: ">") else { break }
                let header = cleaned[cleaned.index(after: i)..<close].lowercased()
                lastHeader = header
                switch header {
                case "global": group = [:]
                case "group": group = [:]
                case "region": inRegion = true
                default: break // control/master/curve… ignored
                }
                i = cleaned.index(after: close)
            } else if cleaned[i].isLetter || cleaned[i] == "_" {
                // Read "key" up to '=', then the value until the next opcode
                // or header (values may contain spaces, e.g. sample paths).
                guard let eq = cleaned[i...].firstIndex(of: "=") else { break }
                let key = String(cleaned[i..<eq]).lowercased()
                let valueStart = cleaned.index(after: eq)
                let rest = cleaned[valueStart...]
                var valueEnd = cleaned.endIndex
                for pattern in [#"\s+[a-zA-Z_0-9]+\s*="#, #"\s*<"#] {
                    if let r = rest.range(of: pattern, options: .regularExpression), r.lowerBound < valueEnd {
                        valueEnd = r.lowerBound
                    }
                }
                let value = String(cleaned[valueStart..<valueEnd])
                    .trimmingCharacters(in: .whitespaces)
                if inRegion {
                    pending[key] = value
                } else if lastHeader == "global" {
                    global[key] = value
                } else if lastHeader == "control" {
                    control[key] = value
                } else {
                    group[key] = value
                }
                i = valueEnd
            } else {
                i = cleaned.index(after: i)
            }
        }
        flushRegion()
        var program = SfzProgram(regions: regions)
        for (key, value) in control {
            guard let r = key.range(of: #"^set_cc(\d+)$"#, options: .regularExpression),
                  let cc = Int(key[r].dropFirst(6)), let v = Int(value) else { continue }
            program.controlDefaults[cc] = v
        }
        return program
    }
}

/// Parse an SFZ key token: a MIDI number ("60") or a note name ("c4" = 60,
/// "c#3", "db2", case-insensitive). Octave digits may be negative ("c-1").
public func sfzKeyNumber(_ token: String) -> Int? {
    let t = token.trimmingCharacters(in: .whitespaces).lowercased()
    if let n = Int(t) { return n }
    guard let letter = t.first else { return nil }
    let base: Int
    switch letter {
    case "c": base = 0
    case "d": base = 2
    case "e": base = 4
    case "f": base = 5
    case "g": base = 7
    case "a": base = 9
    case "b": base = 11
    default: return nil
    }
    var rest = t.dropFirst()
    var semitone = base
    if rest.first == "#" { semitone += 1; rest = rest.dropFirst() }
    else if rest.first == "b" { semitone -= 1; rest = rest.dropFirst() }
    guard let octave = Int(rest) else { return nil }
    return (octave + 1) * 12 + semitone
}

/// First sustain loop of a WAV file's `smpl` chunk, as frame offsets (nil if
/// the chunk or a forward loop is absent). Chunk sizes are little-endian;
/// odd-sized chunks are padded to even.
public func readWavLoop(_ bytes: [UInt8]) -> (start: Int, length: Int)? {
    guard bytes.count > 12,
          bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46, // RIFF
          bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 // WAVE
    else { return nil }
    func u32(_ at: Int) -> Int {
        guard at + 4 <= bytes.count else { return 0 }
        return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    }
    var offset = 12
    while offset + 8 <= bytes.count {
        let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
        let size = u32(offset + 4)
        if id == "smpl", offset + 8 + size <= bytes.count {
            let base = offset + 8
            let loopCount = u32(base + 28)
            guard loopCount > 0 else { return nil }
            let first = base + 36
            guard first + 24 <= bytes.count else { return nil }
            let type = u32(first + 4) // 0 = forward
            let start = u32(first + 8)
            let end = u32(first + 12) // inclusive per the smpl spec
            guard type == 0, end > start else { return nil }
            return (start, end - start + 1)
        }
        offset += 8 + size + (size % 2)
    }
    return nil
}
