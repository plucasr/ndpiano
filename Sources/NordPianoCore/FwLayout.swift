import Foundation

/// A firmware-registry program layout (OpenNord `block-chain.ts` model):
/// named blocks at fixed body offsets, bit fields inside them.
struct FwLayout {
    struct Block { let offset: Int; let length: Int }

    enum Encoding { case u, offset, twos, raw }

    struct Field {
        let key: String
        let block: Int
        let bit: Int
        let width: Int
        let min: Int
        let max: Int
        let enc: Encoding
    }

    let versionRange: ClosedRange<Int>
    let bodyBytes: Int
    let blocks: [Block]
    let fields: [Field]
}

/// A decoded firmware-registry program (`.nw2p`, `.ne6p`, `.ns4p`): every
/// layout field by key, or `layoutMatched == false` for a file that doesn't fit.
public struct FwProgram {
    public let formatVersion: Int?
    public let layoutMatched: Bool
    public let values: [String: Int]
    public let warnings: [String]

    public func value(_ key: String) -> Int? { values[key] }
}
