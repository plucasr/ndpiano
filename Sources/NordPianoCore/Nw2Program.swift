import Foundation

/// NW2 conveniences on a decoded program: slot enable/source from the
/// MultiCommon block. ("Fw" = firmware-registry formats; `.nw2p` here.)
public typealias Nw2Program = FwProgram

public extension FwProgram {
    static let nw2Slots = ["A", "B", "C", "D"]
    /// Edt_Syn_kOscBank value that selects a Sample Library sample.
    static let nw2OscBankSamples = 4

    /// Whether a NW2 slot is on (bit of Edt_Com_kSlotEnable; nil = mismatch).
    func nw2SlotEnabled(_ slot: String) -> Bool? {
        guard let mask = values["common.slotEnable"] else { return nil }
        return ((mask >> (FwProgram.nw2Slots.firstIndex(of: slot) ?? 0)) & 1) == 1
    }

    /// A NW2 slot's sound source: oscillator bank + wave (sample-list position
    /// when the bank is Samples).
    func nw2SlotSource(_ slot: String) -> (bank: Int, isSample: Bool, wave: Int)? {
        guard let bank = values["slot\(slot)Common.oscBank"],
              let wave = values["slot\(slot)Common.oscWave"] else { return nil }
        return (bank, bank == FwProgram.nw2OscBankSamples, wave)
    }
}

/// Block-chain reader for the firmware-registry program formats (`.nw2p`,
/// `.ne6p`, `.ns4p`). Port of OpenNord's `clavia/block-chain.ts` (AGPL-3.0),
/// read-only, never throws.
public enum FwDecoder {

    public static func decodeNw2(_ bytes: [UInt8]) -> FwProgram { decode(bytes, layout: Nw2Layout.layout) }
    public static func decodeNe6(_ bytes: [UInt8]) -> FwProgram { decode(bytes, layout: Ne6Layout.layout) }
    public static func decodeNs4(_ bytes: [UInt8]) -> FwProgram { decode(bytes, layout: Ns4Layout.layout) }

    /// Decode a program file (CBIN header + block-chain body) against a layout.
    static func decode(_ bytes: [UInt8], layout: FwLayout) -> FwProgram {
        // CBIN body: our files carry the NSM-era header, body from 0x2C to EOF.
        let bodyStart = 0x2C
        guard bytes.count > bodyStart + 4 else {
            return FwProgram(formatVersion: nil, layoutMatched: false,
                             values: [:], warnings: ["file too short for a CBIN body"])
        }
        return decodeBody(Array(bytes[bodyStart...]), layout: layout)
    }

    /// Decode a program body: u32 BE format version, then length-prefixed
    /// blocks of MSB-first bit fields ending exactly at EOF.
    static func decodeBody(_ body: [UInt8], layout: FwLayout) -> FwProgram {
        var warnings: [String] = []
        let formatVersion = body.count >= 4
            ? Int(body[0]) << 24 | Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3])
            : nil

        // Walk the chain.
        var blocks: [(offset: Int, length: Int)] = []
        var pos = 4
        var walkError: String?
        while pos < body.count {
            let length = Int(body[pos])
            if pos + 1 + length > body.count {
                walkError = "block \(blocks.count + 1) at body byte \(pos) claims \(length) bytes but only \(body.count - pos - 1) remain"
                break
            }
            blocks.append((pos, length))
            pos += 1 + length
        }
        if blocks.isEmpty { walkError = walkError ?? "no blocks after the format version" }
        guard walkError == nil, blocks.count == layout.blocks.count else {
            let reason = walkError
                ?? "expected \(layout.blocks.count) blocks, found \(blocks.count) — a layout variant we have not seen"
            return FwProgram(formatVersion: formatVersion, layoutMatched: false,
                             values: [:], warnings: [reason])
        }
        if let v = formatVersion, !layout.versionRange.contains(v) {
            warnings.append("format version \(v) outside \(layout.versionRange.lowerBound)–\(layout.versionRange.upperBound); values may be off")
        }

        var values: [String: Int] = [:]
        var outOfRange: [String] = []
        for f in layout.fields {
            let block = blocks[f.block]
            guard f.bit + f.width <= block.length * 8 else { continue } // shortened block
            let raw = readBits(body, from: (block.offset + 1) * 8 + f.bit, width: f.width)
            let value: Int
            switch f.enc {
            case .offset: value = raw + f.min
            case .twos: value = raw >= (1 << (f.width - 1)) ? raw - (1 << f.width) : raw
            default: value = raw
            }
            if f.enc != .raw && (value < f.min || value > f.max) { outOfRange.append(f.key) }
            values[f.key] = value
        }
        if !outOfRange.isEmpty {
            warnings.append("\(outOfRange.count) value(s) outside the instrument's range")
        }
        return FwProgram(formatVersion: formatVersion, layoutMatched: true,
                         values: values, warnings: warnings)
    }

    /// MSB-first bit-field read: bit 0 is the MSB of byte 0.
    private static func readBits(_ bytes: [UInt8], from bitOffset: Int, width: Int) -> Int {
        var value = 0
        for i in 0..<width {
            let bit = bitOffset + i
            let b = (Int(bytes[bit / 8]) >> (7 - (bit % 8))) & 1
            value = (value << 1) | b
        }
        return value
    }
}
