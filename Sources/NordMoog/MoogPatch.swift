import Foundation

/// The full parameter set of a Moog-style mono voice — what a preset stores
/// and what the moog FX panel edits. Physical units (Hz, seconds, cents) so a
/// patch is display-ready without curve tables; Codable for JSON presets.
public struct MoogPatch: Equatable, Codable, Sendable {
    // Oscillator bank
    /// Osc 1/2/3 waveforms: saw vs pulse (Minimoog also has triangle etc.;
    /// kept to the two lead essentials for the minimal voice).
    public var osc1Pulse = false
    public var osc2Pulse = false
    public var osc3Pulse = false
    /// Osc 2/3 detune in cents (−1200…1200); osc 1 is the reference.
    public var osc2DetuneCents: Double = 6
    public var osc3DetuneCents: Double = -6
    /// Osc 3 octave shift (−1 = one octave below, classic "3rd osc as sub").
    public var osc3Octave: Int = 0
    /// Pulse width 0.1…0.9 for the pulse waves.
    public var pulseWidth: Double = 0.5

    // Mixer (0…1 each; the Minimoog mixer overdrives past ~0.7)
    public var osc1Level: Double = 0.8
    public var osc2Level: Double = 0.8
    public var osc3Level: Double = 0
    public var noiseLevel: Double = 0

    // Filter (4-pole ladder)
    public var cutoffHz: Double = 1200
    /// Resonance ("emphasis") 0…1; self-oscillates past ~0.9.
    public var resonance: Double = 0.2
    /// Filter envelope sweep in octaves, bipolar (−4…+4).
    public var filterEnvOctaves: Double = 2
    /// Keyboard tracking 0…1 (1 = cutoff follows the played note).
    public var keyTrack: Double = 0.3

    // Contours (seconds; sustain is a level 0…1)
    public var filterAttack: Double = 0.005
    public var filterDecay: Double = 0.15
    public var filterSustain: Double = 0.4
    public var filterRelease: Double = 0.1
    public var ampAttack: Double = 0.003
    public var ampDecay: Double = 0.2
    public var ampSustain: Double = 1
    public var ampRelease: Double = 0.15

    // Playing
    /// Portamento time in seconds (0 = off). Exponential approach.
    public var glideSeconds: Double = 0.05
    /// Master level 0…1.
    public var volume: Double = 0.8

    public init() {}

    /// Backward/authoring-friendly decoding: any missing key falls back to the
    /// default patch value, so partial and hand-written presets stay valid.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = MoogPatch()
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        osc1Pulse = try get(.osc1Pulse, fresh.osc1Pulse)
        osc2Pulse = try get(.osc2Pulse, fresh.osc2Pulse)
        osc3Pulse = try get(.osc3Pulse, fresh.osc3Pulse)
        osc2DetuneCents = try get(.osc2DetuneCents, fresh.osc2DetuneCents)
        osc3DetuneCents = try get(.osc3DetuneCents, fresh.osc3DetuneCents)
        osc3Octave = try get(.osc3Octave, fresh.osc3Octave)
        pulseWidth = try get(.pulseWidth, fresh.pulseWidth)
        osc1Level = try get(.osc1Level, fresh.osc1Level)
        osc2Level = try get(.osc2Level, fresh.osc2Level)
        osc3Level = try get(.osc3Level, fresh.osc3Level)
        noiseLevel = try get(.noiseLevel, fresh.noiseLevel)
        cutoffHz = try get(.cutoffHz, fresh.cutoffHz)
        resonance = try get(.resonance, fresh.resonance)
        filterEnvOctaves = try get(.filterEnvOctaves, fresh.filterEnvOctaves)
        keyTrack = try get(.keyTrack, fresh.keyTrack)
        filterAttack = try get(.filterAttack, fresh.filterAttack)
        filterDecay = try get(.filterDecay, fresh.filterDecay)
        filterSustain = try get(.filterSustain, fresh.filterSustain)
        filterRelease = try get(.filterRelease, fresh.filterRelease)
        ampAttack = try get(.ampAttack, fresh.ampAttack)
        ampDecay = try get(.ampDecay, fresh.ampDecay)
        ampSustain = try get(.ampSustain, fresh.ampSustain)
        ampRelease = try get(.ampRelease, fresh.ampRelease)
        glideSeconds = try get(.glideSeconds, fresh.glideSeconds)
        volume = try get(.volume, fresh.volume)
    }

    /// Sensible mono lead starting point.
    public static let lead = MoogPatch()
}
