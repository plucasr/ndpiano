import Foundation

/// A `.moog` file: one named MoogPatch as JSON. The wrapped form carries the
/// display name; a bare MoogPatch object also decodes, so hand-written presets
/// can skip the envelope.
public struct MoogPreset: Codable, Sendable {
    public var name: String
    /// Optional so hand-written `{name, patch}` files still decode.
    public var version: Int?
    public var patch: MoogPatch

    public init(name: String, patch: MoogPatch) {
        self.name = name
        self.version = 1
        self.patch = patch
    }

    public static func decode(from data: Data) throws -> MoogPreset {
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(MoogPreset.self, from: data) {
            return wrapped
        }
        return MoogPreset(name: "Imported preset", patch: try decoder.decode(MoogPatch.self, from: data))
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
