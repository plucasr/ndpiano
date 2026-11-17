import Foundation

/// The factory preset bank: seeded into the catalog on first launch so the
/// MOOG panel has playable starting points. Values are tuned for the
/// MoogVoice engine (see MoogPatch for units).
public enum MoogFactory {

    /// (name, patch) pairs, in panel order.
    public static let presets: [(name: String, patch: MoogPatch)] = [
        ("Mini Lead", miniLead),
        ("Prog Lead", progLead),
        ("Square Lead", squareLead),
        ("Soft Flute", softFlute),
        ("Pulse Bass", pulseBass),
        ("Sub Bass", subBass),
        ("Reso Sweep", resoSweep),
    ]

    /// The classic: three detuned saws, a touch of glide, mid-open filter.
    public static var miniLead: MoogPatch {
        var p = MoogPatch()
        p.cutoffHz = 2400
        p.resonance = 0.18
        p.filterEnvOctaves = 1.5
        p.filterSustain = 0.45
        p.keyTrack = 0.4
        p.osc2DetuneCents = 8
        p.osc3DetuneCents = -8
        p.osc3Level = 0.7
        p.glideSeconds = 0.06
        p.ampRelease = 0.12
        return p
    }

    /// Faster, harder lead: more drive through the mixer, snappier contour,
    /// a little longer glide — the prog-rock mono line.
    public static var progLead: MoogPatch {
        var p = MoogPatch()
        p.osc2Pulse = true
        p.osc2DetuneCents = 5
        p.osc3DetuneCents = -5
        p.osc3Level = 0.8
        p.cutoffHz = 3200
        p.resonance = 0.3
        p.filterEnvOctaves = 2.2
        p.filterAttack = 0.002
        p.filterDecay = 0.09
        p.filterSustain = 0.55
        p.keyTrack = 0.5
        p.ampAttack = 0.002
        p.ampRelease = 0.09
        p.glideSeconds = 0.045
        return p
    }

    /// Hollow pulse lead, medium width — the "square wave" voice.
    public static var squareLead: MoogPatch {
        var p = MoogPatch()
        p.osc1Pulse = true
        p.osc2Pulse = true
        p.osc2DetuneCents = 3
        p.osc3Pulse = true
        p.osc3Level = 0.5
        p.pulseWidth = 0.4
        p.cutoffHz = 1800
        p.resonance = 0.12
        p.filterEnvOctaves = 1
        p.filterSustain = 0.6
        p.glideSeconds = 0.08
        p.ampRelease = 0.15
        return p
    }

    /// Mellow flute-ish: low cutoff, no resonance, slowish attack, vibrato-free.
    public static var softFlute: MoogPatch {
        var p = MoogPatch()
        p.osc2Level = 0.3
        p.osc2DetuneCents = 4
        p.cutoffHz = 900
        p.resonance = 0
        p.filterEnvOctaves = 0.6
        p.filterSustain = 0.7
        p.keyTrack = 0.6
        p.ampAttack = 0.04
        p.ampRelease = 0.25
        p.glideSeconds = 0.09
        return p
    }

    /// Snappy pulse bass with a sub octave underneath.
    public static var pulseBass: MoogPatch {
        var p = MoogPatch()
        p.osc1Pulse = true
        p.osc1Level = 0.9
        p.osc2DetuneCents = -1200
        p.osc2Level = 0.7
        p.cutoffHz = 500
        p.resonance = 0.3
        p.filterEnvOctaves = 2.5
        p.filterAttack = 0.002
        p.filterDecay = 0.12
        p.filterSustain = 0.2
        p.keyTrack = 0.2
        p.ampAttack = 0.002
        p.ampDecay = 0.25
        p.ampSustain = 0.85
        p.ampRelease = 0.08
        p.pulseWidth = 0.4
        return p
    }

    /// Deep sine-adjacent sub: third osc one octave down does the weight.
    public static var subBass: MoogPatch {
        var p = MoogPatch()
        p.osc1Level = 0.6
        p.osc2Level = 0.2
        p.osc3Octave = -1
        p.osc3Level = 1
        p.cutoffHz = 300
        p.resonance = 0.1
        p.filterEnvOctaves = 1.2
        p.filterDecay = 0.2
        p.filterSustain = 0.3
        p.ampAttack = 0.004
        p.ampDecay = 0.35
        p.ampSustain = 0.9
        p.ampRelease = 0.1
        return p
    }

    /// Effect voice: self-oscillating filter with noise, for sweeps.
    public static var resoSweep: MoogPatch {
        var p = MoogPatch()
        p.osc1Level = 0.4
        p.osc2Level = 0
        p.noiseLevel = 0.5
        p.cutoffHz = 800
        p.resonance = 0.85
        p.filterEnvOctaves = 3.5
        p.filterAttack = 0.4
        p.filterDecay = 0.8
        p.filterSustain = 0.2
        p.keyTrack = 0.8
        p.ampAttack = 0.02
        p.ampSustain = 1
        p.ampRelease = 0.4
        p.glideSeconds = 0.15
        return p
    }
}
