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

    /// Sensible mono lead starting point.
    public static let lead = MoogPatch()
}
