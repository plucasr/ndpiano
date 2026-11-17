import Foundation
import NordPianoEngine

/// A shareable FX preset: one layer's full FX state as a JSON file, like the
/// meta.xml in a bundle but only performance parameters. The wrapped form
/// carries a display name; a bare LayerFX JSON object also decodes, so
/// hand-written presets can skip the envelope.
struct FXPreset: Codable {
    var name: String
    /// Optional so hand-written `{name, fx}` files still decode.
    var version: Int?
    var fx: PianoPlayer.LayerFX

    init(name: String, fx: PianoPlayer.LayerFX) {
        self.name = name
        self.version = 1
        self.fx = fx
    }

    /// Decode either the wrapped form or a bare LayerFX object (missing keys
    /// fall back to defaults via LayerFX's own decoder).
    static func decode(from data: Data) throws -> FXPreset {
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(FXPreset.self, from: data) {
            return wrapped
        }
        return FXPreset(name: "Imported preset", fx: try decoder.decode(PianoPlayer.LayerFX.self, from: data))
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
