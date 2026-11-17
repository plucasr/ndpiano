import Foundation

/// Knob ↔ physical-unit curves for the synth section, calibrated against the
/// Nord Stage 4 display tables (OpenNord `values.generated.ts`): one place so
/// the engine, the importers and the panel readouts agree.
public enum SynthCurves {
    /// Nord envelope attack, time code 0…127 → seconds (0.5 ms … 45 s).
    private static let attackAnchors: [(Double, Double)] =
        [(0, 0.0005), (32, 0.054), (64, 1.02), (96, 8.72), (127, 45)]
    /// Nord envelope decay/release, 0…127 → seconds (3 ms … 45 s).
    private static let decayAnchors: [(Double, Double)] =
        [(0, 0.003), (32, 0.12), (64, 1.49), (96, 10), (127, 45)]

    /// Log-linear interpolation through (code, seconds) anchors.
    private static func interpolate(_ anchors: [(Double, Double)], _ code: Double) -> Double {
        let x = min(127, max(0, code))
        for i in 1..<anchors.count where x <= anchors[i].0 {
            let (x0, y0) = anchors[i - 1], (x1, y1) = anchors[i]
            let t = (x - x0) / (x1 - x0)
            return exp(log(y0) + (log(y1) - log(y0)) * t)
        }
        return anchors[anchors.count - 1].1
    }

    /// Envelope attack time for a 0…1 knob (Nord curve).
    public static func attackSeconds(_ norm: Double) -> Double { interpolate(attackAnchors, norm * 127) }
    /// Envelope decay/release time for a 0…1 knob (Nord curve).
    public static func decaySeconds(_ norm: Double) -> Double { interpolate(decayAnchors, norm * 127) }

    /// Filter cutoff for a 0…1 knob: exponential 14 Hz … 20 kHz, matching the
    /// Nord frequency display (64 → ~550 Hz) so imported values land right.
    public static func cutoffHz(_ norm: Double) -> Double { min(20_000, 14 * exp(7.3 * norm)) }

    /// Inverse of `cutoffHz`.
    public static func cutoffNorm(hz: Double) -> Double { min(1, max(0, log(max(14, hz) / 14) / 7.3)) }

    /// Channel LFO rate, 0…1 → 0.05 … 20 Hz (exponential).
    public static func lfoHz(_ norm: Double) -> Double { 0.05 * pow(400, norm) }

    /// Vibrato rate, 0…1 → 2 … 8 Hz (Nord range, linear).
    public static func vibratoHz(_ norm: Double) -> Double { 2 + 6 * norm }

    /// Vibrato depth, 0…1 → peak deviation in semitones (0 … 0.5).
    public static func vibratoSemitones(_ norm: Double) -> Double { 0.5 * norm }

    /// Compact time label: "3ms", "1.25s", "∞".
    public static func formatSeconds(_ s: Double) -> String {
        if s.isInfinite { return "∞" }
        if s < 1 { return "\(Int((s * 1000).rounded()))ms" }
        return String(format: s < 10 ? "%.2fs" : "%.0fs", s)
    }

    /// Compact frequency label: "554", "3.5k".
    public static func formatHz(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1fk", hz / 1000) : "\(Int(hz.rounded()))"
    }

    /// MIDI note name with C4 = 60 (Nord convention).
    public static func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[((note % 12) + 12) % 12])\(note / 12 - 1)"
    }
}

/// Nord filter models (stored value = Nord's fltType).
public enum SynthFilterType: Int, CaseIterable {
    case lp12 = 0, lp24, ladder, lpHp, bp, hp24

    public var label: String {
        switch self {
        case .lp12: "LP12"
        case .lp24: "LP24"
        case .ladder: "LADDER"
        case .lpHp: "LP+HP"
        case .bp: "BP"
        case .hp24: "HP24"
        }
    }
}

/// One stereo stage of a zero-delay-feedback state-variable filter (Simper's
/// trapezoidal SVF): stable for any cutoff below Nyquist and any damping > 0,
/// unlike the Chamberlin form, which had to be capped near fs/6.
struct SVFStage {
    var ic1L: Float = 0, ic2L: Float = 0, ic1R: Float = 0, ic2R: Float = 0
    var a1: Float = 1, a2: Float = 0, a3: Float = 0, k: Float = 1.414

    mutating func set(hz: Float, damping: Float, rate: Float) {
        let g = tan(Float.pi * min(hz, 0.45 * rate) / rate)
        k = damping
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    /// Returns (low, band, high) for one sample; `left` picks the state pair.
    @inline(__always)
    mutating func tick(_ x: Float, left: Bool) -> (Float, Float, Float) {
        if left {
            let v3 = x - ic2L
            let v1 = a1 * ic1L + a2 * v3
            let v2 = ic2L + a2 * ic1L + a3 * v3
            ic1L = 2 * v1 - ic1L
            ic2L = 2 * v2 - ic2L
            return (v2, v1, x - k * v1 - v2)
        }
        let v3 = x - ic2R
        let v1 = a1 * ic1R + a2 * v3
        let v2 = ic2R + a2 * ic1R + a3 * v3
        ic1R = 2 * v1 - ic1R
        ic2R = 2 * v2 - ic2R
        return (v2, v1, x - k * v1 - v2)
    }
}

/// A voice's filter: two cascaded SVF stages wired per Nord filter type.
/// Resonance lives on the first stage; the second is a fixed Butterworth-ish
/// stage so the 24 dB types don't double-peak.
struct VoiceFilter {
    var a = SVFStage()
    var b = SVFStage()

    /// Recompute coefficients (control rate). `hpHz` is the LP+HP type's
    /// high-pass corner; other types ignore it.
    mutating func update(hz: Float, hpHz: Float, res: Float, type: Int, rate: Float) {
        let r = min(1, max(0, res))
        func damping(_ base: Float) -> Float { max(0.03, base * (1 - 0.97 * r)) }
        switch type {
        case 0: // LP12
            a.set(hz: hz, damping: damping(1.414), rate: rate)
        case 1, 2: // LP24 / ladder (approximated by the same 4-pole low-pass)
            a.set(hz: hz, damping: damping(0.765), rate: rate)
            b.set(hz: hz, damping: 1.848, rate: rate)
        case 3: // LP+HP
            a.set(hz: hz, damping: damping(1.414), rate: rate)
            b.set(hz: hpHz, damping: 1.414, rate: rate)
        case 4: // BP
            a.set(hz: hz, damping: damping(1.414), rate: rate)
            b.set(hz: hz, damping: 1.414, rate: rate)
        default: // HP24
            a.set(hz: hz, damping: damping(0.765), rate: rate)
            b.set(hz: hz, damping: 1.848, rate: rate)
        }
    }

    @inline(__always)
    mutating func process(_ x: Float, left: Bool, type: Int) -> Float {
        switch type {
        case 0:
            return a.tick(x, left: left).0
        case 1, 2:
            return b.tick(a.tick(x, left: left).0, left: left).0
        case 3:
            return b.tick(a.tick(x, left: left).0, left: left).2
        case 4: // normalized band-pass (unity peak): k · band
            let s1 = a.k * a.tick(x, left: left).1
            return b.k * b.tick(s1, left: left).1
        default:
            return b.tick(a.tick(x, left: left).2, left: left).2
        }
    }
}

/// Channel LFO waveforms (stored value = Nord's lfoWave).
public enum SynthLfoShape: Int, CaseIterable {
    case triangle = 0, saw, invSaw, square, sampleHold

    public var label: String {
        switch self {
        case .triangle: "TRI"
        case .saw: "SAW"
        case .invSaw: "INV SAW"
        case .square: "SQR"
        case .sampleHold: "S/H"
        }
    }

    /// Bipolar value −1…1 at phase 0…1 (S/H returns `hold`).
    @inline(__always)
    func value(_ p: Double, hold: Float) -> Float {
        switch self {
        case .triangle: Float(1 - 4 * abs(p - 0.5))
        case .saw: Float(2 * p - 1)
        case .invSaw: Float(1 - 2 * p)
        case .square: p < 0.5 ? 1 : -1
        case .sampleHold: hold
        }
    }
}

/// What the channel LFO modulates.
public enum SynthLfoDest: Int, CaseIterable {
    case amp = 0, pitch, filter

    public var label: String {
        switch self {
        case .amp: "AMP"
        case .pitch: "PITCH"
        case .filter: "FILTER"
        }
    }
}

/// Vibrato source (stored value = Nord's vibMode).
public enum SynthVibratoMode: Int, CaseIterable {
    case off = 0, on, delayed, wheel, aftertouch, pedal

    public var label: String {
        switch self {
        case .off: "OFF"
        case .on: "ON"
        case .delayed: "DELAY"
        case .wheel: "WHEEL"
        case .aftertouch: "A.T."
        case .pedal: "PEDAL"
        }
    }
}

/// Mono note priority (stored value = Nord's voicePrio).
public enum SynthVoicePriority: Int, CaseIterable {
    case last = 0, low, high

    public var label: String {
        switch self {
        case .last: "LAST"
        case .low: "LOW"
        case .high: "HIGH"
        }
    }

    /// The note that should sound among `held` (oldest first).
    func winner(_ held: [(note: Int, velocity: Int)]) -> (note: Int, velocity: Int)? {
        switch self {
        case .last: held.last
        case .low: held.min { $0.note < $1.note }
        case .high: held.max { $0.note < $1.note }
        }
    }
}

/// Per-block modulation for one channel, computed once per render call (not
/// per voice — advancing the LFO inside the voice loop ran it N× fast).
struct ModBlock {
    var amp: UnsafeMutablePointer<Float>
    var pitch: UnsafeMutablePointer<Float>
    var vibrato: UnsafeMutablePointer<Float>
    var filter: UnsafeMutablePointer<Float>
    var capacity: Int
    var ampActive = false
    var pitchActive = false
    var vibratoActive = false
    var filterActive = false
    /// Vibrato fade-in for the DELAY mode, in output frames (0 = none).
    var vibratoDelayFrames: Float = 0
}

// MARK: - Arpeggiator

/// Arpeggiator mode (stored value = Nord's arpMode): Arp steps through the
/// held notes one at a time; Poly retriggers the whole chord each step (moving
/// through the octave range); Gate retriggers the chord in place.
public enum SynthArpMode: Int, CaseIterable {
    case arp = 0, poly, gate

    public var label: String {
        switch self {
        case .arp: "ARP"
        case .poly: "POLY"
        case .gate: "GATE"
        }
    }
}

/// Arpeggiator direction (stored value = Nord's arpDir).
public enum SynthArpDirection: Int, CaseIterable {
    case up = 0, down, upDown, random

    public var label: String {
        switch self {
        case .up: "UP"
        case .down: "DOWN"
        case .upDown: "UP/DN"
        case .random: "RANDOM"
        }
    }
}

extension SynthCurves {
    /// Arpeggiator rate, 0…1 → 1 … 30 steps per second (exponential).
    public static func arpStepsPerSecond(_ norm: Double) -> Double { pow(30, min(1, max(0, norm))) }

    /// The tempo at which one arp step is a 16th note.
    public static func arpBPM(_ norm: Double) -> Double { arpStepsPerSecond(norm) * 15 }
}

/// Arpeggiator step logic, independent of timing (unit-testable): given the
/// held keys, produce the notes for the next step and advance the counter.
struct ArpSequencer {
    var step = 0
    var seed: UInt32 = 0x2545_F491

    /// Notes (with velocities) to sound at the next step. `held` in any order.
    mutating func next(held: [(note: Int, velocity: Int)], mode: SynthArpMode,
                       direction: SynthArpDirection, octaves: Int) -> [(note: Int, velocity: Int)] {
        let sorted = held.sorted { $0.note < $1.note }
        guard !sorted.isEmpty else { return [] }
        let range = min(4, max(1, octaves))
        defer { step += 1 }
        switch mode {
        case .arp:
            var sequence: [(note: Int, velocity: Int)] = []
            for octave in 0..<range {
                sequence += sorted.map { ($0.note + 12 * octave, $0.velocity) }
            }
            return [sequence[index(count: sequence.count, direction: direction)]]
        case .poly:
            let octave = index(count: range, direction: direction)
            return sorted.map { ($0.note + 12 * octave, $0.velocity) }
        case .gate:
            return sorted
        }
    }

    /// Position for the current step within `count` items.
    private mutating func index(count: Int, direction: SynthArpDirection) -> Int {
        guard count > 1 else { return 0 }
        switch direction {
        case .up:
            return step % count
        case .down:
            return count - 1 - step % count
        case .upDown:
            // Ping-pong without repeating the turning points: 0 1 2 3 2 1 0 1 …
            let p = step % (2 * count - 2)
            return p < count ? p : 2 * count - 2 - p
        case .random:
            seed ^= seed << 13
            seed ^= seed >> 17
            seed ^= seed << 5
            return Int(seed % UInt32(count))
        }
    }
}
