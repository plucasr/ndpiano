import Foundation

/// Anti-aliased oscillator core: saw and pulse via PolyBLEP (the standard
/// polynomial correction at the discontinuity), band-limited to ~Nyquist.
struct PolyBlepOsc {
    var phase: Double = 0 // cycles, 0…1

    @inline(__always)
    private func blep(_ t: Double, _ dt: Double) -> Double {
        if t < dt { let x = t / dt; return 2 * x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + 2 * x + 1 }
        return 0
    }

    /// One sample of saw or pulse at `dt` cycles/sample.
    @inline(__always)
    mutating func tick(dt: Double, pulse: Bool, width: Double) -> Float {
        phase += dt
        if phase >= 1 { phase -= 1 }
        if !pulse {
            return Float(2 * phase - 1 - blep(phase, dt))
        }
        var t2 = phase - width
        if t2 < 0 { t2 += 1 }
        let s = (phase < width ? 1.0 : -1.0) + blep(phase, dt) - blep(t2, dt)
        return Float(s)
    }
}

/// One ADSR contour; linear segments are fine at lead-typical times and keep
/// the state machine obvious. Times in seconds, sustain a level 0…1.
struct Contour {
    enum Stage { case idle, attack, decay, sustain, release }
    private(set) var stage: Stage = .idle
    private(set) var level: Double = 0

    mutating func gateOn() { stage = .attack }
    mutating func gateOff() { if stage != .idle { stage = .release } }
    mutating func kill() { stage = .idle; level = 0 }

    /// Advance one sample; returns the level.
    @inline(__always)
    mutating func tick(a: Double, d: Double, s: Double, r: Double, rate: Double) -> Double {
        switch stage {
        case .idle: break
        case .attack:
            level += 1 / (max(a, 0.0005) * rate)
            if level >= 1 { level = 1; stage = .decay }
        case .decay:
            level -= (1 - s) / (max(d, 0.001) * rate)
            if level <= s { level = s; stage = .sustain }
        case .sustain: break
        case .release:
            level -= level / (max(r, 0.003) * rate) + 1e-6
            if level < 0.0005 { kill() }
        }
        return level
    }
}

/// 4-pole Moog-style ladder: four cascaded one-poles with global feedback.
/// `k = 4 × resonance` sends it into self-oscillation near the top, and the
/// tanh in the feedback path is the soft overload the mixer drive leans on.
struct Ladder {
    private var s: (Double, Double, Double, Double) = (0, 0, 0, 0)

    @inline(__always)
    mutating func tick(_ input: Double, hz: Double, res: Double, rate: Double) -> Double {
        let g = 1 - exp(-2 * .pi * min(hz, 0.45 * rate) / rate)
        let k = 4 * min(0.99, max(0, res))
        let x = (input - k * s.3) / (1 + k * g) // pre-compensated feedback
        let d = tanh(x)
        s.0 += g * (d - s.0)
        s.1 += g * (s.0 - s.1)
        s.2 += g * (s.1 - s.2)
        s.3 += g * (s.2 - s.3)
        return s.3
    }
}

/// A Minimoog-style mono voice: oscillator bank → mixer → ladder filter →
/// amp contour. Mono by construction with last-note priority, legato (no
/// retrigger while keys overlap) and exponential glide.
public final class MoogVoice {
    public var patch: MoogPatch
    public let sampleRate: Double

    /// Held notes, oldest first. Last-note priority (Minimoog default).
    private var held: [(note: Int, velocity: Int)] = []
    private var velocityLevel = 1.0
    private var currentHz = 440.0
    private var osc = (PolyBlepOsc(), PolyBlepOsc(), PolyBlepOsc())
    private var ladder = Ladder()
    private var filterEnv = Contour()
    private var ampEnv = Contour()
    private var noiseSeed: UInt32 = 22222

    /// Live pitch after glide, exposed for tests and UI.
    public private(set) var pitchHz = 440.0
    /// True once the amp contour has finished after the last note-off.
    public var isSilent: Bool { held.isEmpty && ampEnv.stage == .idle }

    public init(patch: MoogPatch = .lead, sampleRate: Double = 48_000) {
        self.patch = patch
        self.sampleRate = sampleRate
    }

    public func noteOn(note: Int, velocity: Int) {
        let retrigger = held.isEmpty
        held.removeAll { $0.note == note }
        held.append((note, velocity))
        velocityLevel = pow(Double(velocity) / 127, 1.5)
        let target = Self.noteHz(note)
        if retrigger {
            currentHz = patch.glideSeconds > 0 ? currentHz : target
            filterEnv.gateOn()
            ampEnv.gateOn()
        }
        // Legato overlap: pitch moves (glide if on), contours keep running.
    }

    public func noteOff(note: Int) {
        if let i = held.lastIndex(where: { $0.note == note }) {
            let wasTop = i == held.count - 1
            held.remove(at: i)
            if wasTop, let next = held.last {
                velocityLevel = pow(Double(next.velocity) / 127, 1.5)
            }
        }
        if held.isEmpty {
            filterEnv.gateOff()
            ampEnv.gateOff()
        }
    }

    public func allNotesOff() {
        held.removeAll()
        filterEnv.kill()
        ampEnv.kill()
    }

    static func noteHz(_ note: Int) -> Double {
        440 * pow(2, Double(note - 69) / 12)
    }

    /// Render `frames` of mono audio into `out` (added to existing contents,
    /// so several layers can share a buffer).
    public func render(into out: UnsafeMutableBufferPointer<Float>, frames: Int) {
        guard !isSilent else { return }
        let p = patch
        let rate = sampleRate
        let targetHz = held.last.map { Self.noteHz($0.note) } ?? currentHz
        // Exponential glide: time constant ≈ 1/5 of the set time (5τ ≈ settled).
        let glideCoef = p.glideSeconds > 0 ? exp(-5 / (p.glideSeconds * rate)) : 0.0
        let osc2Mul = pow(2, p.osc2DetuneCents / 1200)
        let osc3Mul = pow(2, Double(p.osc3Octave) + p.osc3DetuneCents / 1200)
        let mixerDrive = 1.0 // fixed for the minimal voice; drive lives in ladder tanh
        for i in 0..<frames {
            if glideCoef > 0 {
                currentHz = targetHz + (currentHz - targetHz) * glideCoef
            } else {
                currentHz = targetHz
            }
            pitchHz = currentHz

            let fEnv = filterEnv.tick(a: p.filterAttack, d: p.filterDecay,
                                      s: p.filterSustain, r: p.filterRelease, rate: rate)
            let aEnv = ampEnv.tick(a: p.ampAttack, d: p.ampDecay,
                                   s: p.ampSustain, r: p.ampRelease, rate: rate)

            let dt = currentHz / rate
            let mixed = p.osc1Level * Double(osc.0.tick(dt: dt, pulse: p.osc1Pulse, width: p.pulseWidth))
                + p.osc2Level * Double(osc.1.tick(dt: dt * osc2Mul, pulse: p.osc2Pulse, width: p.pulseWidth))
                + p.osc3Level * Double(osc.2.tick(dt: dt * osc3Mul, pulse: p.osc3Pulse, width: p.pulseWidth))
                + p.noiseLevel * Double(noise())

            // Cutoff: knob, key tracking, and the contour sweep (octaves).
            let noteOctaves = log2(max(1, currentHz) / 261.63) // relative to C4
            let cutoff = p.cutoffHz
                * pow(2, p.keyTrack * noteOctaves + p.filterEnvOctaves * fEnv)
            let filtered = ladder.tick(mixed * mixerDrive, hz: cutoff, res: p.resonance, rate: rate)

            out[i] += Float(filtered * aEnv * velocityLevel * p.volume)
        }
    }

    /// Cheap white noise, −1…1.
    @inline(__always)
    private func noise() -> Float {
        noiseSeed ^= noiseSeed << 13
        noiseSeed ^= noiseSeed >> 17
        noiseSeed ^= noiseSeed << 5
        return Float(Int32(bitPattern: noiseSeed)) / Float(Int32.max)
    }
}
