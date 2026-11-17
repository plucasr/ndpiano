/// Nord Stage 4 keyboard zones: which of the four split zones a layer plays,
/// from its `kbZone` value and the program's three split-point switches.
/// Table ported from OpenNord's dependency tables (ns4decode, MIT —
/// THIRD_PARTY_LICENSES in OpenNord); identical for piano, organ and synth.
public enum Ns4Zones {
    /// Split-point notes (Nord C4 = MIDI 60), index = `common.splitPos*`.
    public static let splitNotes = [36, 41, 48, 53, 60, 65, 72, 77, 84, 89, 96]

    /// Zone mask per "lowOn:midOn:highOn:kbZone" key; bit 0 = lowest zone.
    static let table: [String: UInt8] = [
        "0:0:0:0": 15, "0:0:0:1": 15, "0:0:0:2": 15, "0:0:0:3": 15, "0:0:0:4": 15, "0:0:0:5": 15,
        "0:0:0:6": 15, "0:0:0:7": 15, "0:0:0:8": 15, "0:0:0:9": 15, "0:0:0:10": 15, "0:0:1:0": 7,
        "0:0:1:1": 7, "0:0:1:2": 7, "0:0:1:3": 7, "0:0:1:4": 7, "0:0:1:5": 15, "0:0:1:6": 8,
        "0:0:1:7": 8, "0:0:1:8": 8, "0:0:1:9": 8, "0:0:1:10": 8, "0:1:0:0": 3, "0:1:0:1": 3,
        "0:1:0:2": 3, "0:1:0:3": 3, "0:1:0:4": 3, "0:1:0:5": 15, "0:1:0:6": 12, "0:1:0:7": 12,
        "0:1:0:8": 12, "0:1:0:9": 12, "0:1:0:10": 12, "0:1:1:0": 3, "0:1:1:1": 4, "0:1:1:2": 7,
        "0:1:1:3": 7, "0:1:1:4": 7, "0:1:1:5": 15, "0:1:1:6": 12, "0:1:1:7": 12, "0:1:1:8": 12,
        "0:1:1:9": 4, "0:1:1:10": 8, "1:0:0:0": 1, "1:0:0:1": 1, "1:0:0:2": 1, "1:0:0:3": 1,
        "1:0:0:4": 1, "1:0:0:5": 15, "1:0:0:6": 14, "1:0:0:7": 14, "1:0:0:8": 14, "1:0:0:9": 14,
        "1:0:0:10": 14, "1:0:1:0": 1, "1:0:1:1": 6, "1:0:1:2": 7, "1:0:1:3": 7, "1:0:1:4": 7,
        "1:0:1:5": 15, "1:0:1:6": 14, "1:0:1:7": 14, "1:0:1:8": 14, "1:0:1:9": 6, "1:0:1:10": 8,
        "1:1:0:0": 1, "1:1:0:1": 2, "1:1:0:2": 3, "1:1:0:3": 3, "1:1:0:4": 3, "1:1:0:5": 15,
        "1:1:0:6": 14, "1:1:0:7": 14, "1:1:0:8": 14, "1:1:0:9": 2, "1:1:0:10": 12, "1:1:1:0": 1,
        "1:1:1:1": 2, "1:1:1:2": 3, "1:1:1:3": 6, "1:1:1:4": 7, "1:1:1:5": 15, "1:1:1:6": 14,
        "1:1:1:7": 6, "1:1:1:8": 12, "1:1:1:9": 4, "1:1:1:10": 8,
    ]

    /// MIDI key range a layer covers, or nil when it plays nowhere. `split`
    /// is the program's master split switch; off = whole keyboard.
    public static func keyRange(kbZone: Int, split: Bool,
                                points: [(enabled: Bool, position: Int)]) -> ClosedRange<Int>? {
        guard split, points.count == 3 else { return 0...127 }
        let flags = points.map { $0.enabled ? "1" : "0" }.joined(separator: ":")
        guard let mask = table["\(flags):\(kbZone)"] else { return 0...127 }
        guard mask != 0 else { return nil }
        let zones = (0..<4).filter { mask & (1 << $0) != 0 }
        let lowZone = zones.first!, highZone = zones.last!
        // Zone k spans from the nearest enabled split point below it to the
        // next enabled one above (the split note belongs to the upper zone).
        func note(_ i: Int) -> Int { splitNotes[min(splitNotes.count - 1, max(0, points[i].position))] }
        let low = (0..<lowZone).reversed().first { points[$0].enabled }.map(note) ?? 0
        let high = (highZone..<3).first { points[$0].enabled }.map { note($0) - 1 } ?? 127
        return low <= high ? low...high : nil
    }
}
