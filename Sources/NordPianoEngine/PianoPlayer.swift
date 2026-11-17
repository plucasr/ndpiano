import Foundation
import CoreAudio
import CoreMIDI
import AVFAudio
import AudioToolbox
import NordPianoCore
import NordMoog

/// Real-time piano voice: one decoded stroke being played.
/// Live controller positions (each 0…1) that drive program morphs.
struct MorphSources {
    var wheel: Float = 0
    var aftertouch: Float = 0
    var pedal: Float = 0
}

private struct Voice {
    var pcm: [[Float]] // per channel, normalized −1…1, 44.1 kHz
    var pos: Double = 0 // source-frame position (fractional for pitch)
    var rate: Double // source frames per output frame
    var gain: Float // touch level × headroom × layer gain
    var env: Float = 1 // release envelope
    /// Per-frame env increment while the attack phase runs (0 = attack done / none).
    var attackStep: Float = 0
    var releasing = false
    var sustained = false
    var note: Int
    var loopStart: Double = 0
    var loopEnd: Double = 0
    var hasLoop = false
    var loopDecayPerFrame: Float = 1
    /// One-shot: ignores note-off, plays to the sample end.
    var oneShot = false
    /// Glide: actual rate slides from the previous note toward `rate`
    /// (0 = no glide, use rate). Per-frame approach coefficient.
    var currentRate: Double = 0
    var glideCoef: Double = 0
    /// Per-voice resonant filter (ZDF SVF stages) — used when the layer's filter is on.
    var filter = VoiceFilter()
    /// Filter keyboard tracking: cutoff multiplier for this note (1 = none).
    var keyTrackMul: Float = 1
    /// Amp envelope decay → sustain: per-frame approach coefficient toward
    /// `ampSus` once the attack is done (1 = no decay stage).
    var ampDecayCoef: Float = 1
    var ampSus: Float = 1
    /// Mono hand-off: a fast (~4 ms) release instead of the channel's tail.
    var choke = false
    /// Frames since note-on (vibrato delay fade-in).
    var age: Int = 0
    /// Filter envelope: level 0…1, stage (0 attack, 1 decay, 2 sustain),
    /// per-frame steps precomputed at note-on (release follows `releasing`).
    var fltEnv: Float = 0
    var fltStage = 0
    var fltAtkStep: Float = 0
    var fltDcyStep: Float = 0
    var fltSus: Float = 1
    var fltRlsStep: Float = 0
    /// Note-on scaling of the filter-envelope sweep (fltEnvVel), 0…1.
    var fltEnvScale: Float = 1
    /// Velocity → cutoff morph, as an offset in cutoff-knob space (−1…1).
    var velCutoff: Float = 0
}

/// A decoded stroke ready for playback (piano or sample).
struct CachedStroke {
    var pcm: [[Float]]
    var sampleRate: Double
    /// Sustain loop in frames; nil = one-shot. `start + length` may be shorter
    /// than the audio (a post-loop tail exists).
    var loop: (start: Int, length: Int)?
    var decayDbPerSecond: Double
}

/// What a layer plays: a piano library (`.npno`, NSP/CNSP codec), a Nord Sample
/// (`.nsmp3`/`.nsmp4`, NW1 codec 3/4), an SFZ program (plain WAV regions), or a
/// SoundFont (`.sf2`) rendered by Apple's AUSampler in the channel strip.
/// Sample strokes decode lazily on first note, cached per layer like piano strokes.
enum LayerSource {
    case piano(bytes: [UInt8], dir: NspDirectory, zones: [NspZone])
    case sample(bytes: [UInt8], zones: [NsmpZone])
    /// SFZ: parsed regions + the .sfz file's directory (sample paths are relative),
    /// plus the <control> CC defaults (initial controller state, 0…127).
    case sfz(regions: [SfzRegion], directory: URL, controlDefaults: [Int: Int])
    /// SF2/DLS: no decoding of our own — an AVAudioUnitSampler in the channel's
    /// graph position loads the bank; notes are forwarded as MIDI messages.
    case soundFont(url: URL)
    /// Moog-style mono lead voice (NordMoog module): synthesized live in the
    /// channel's render callback, no samples involved.
    case moog
}

struct Layer {
    let id: UUID
    var gain: Float
    var muted = false
    var cache: [Int: CachedStroke] = [:]
    var source: LayerSource
    /// Sample strokes decoded so far (keyed by global id); `sampleDecoded` marks the
    /// whole-file decode having run (a stroke may legitimately be absent).
    var sampleCache: [Int: CachedStroke] = [:]
    var sampleDecoded = false

    /// The SFZ <control> CC defaults ([:] for pianos and Nord samples).
    var controlDefaultsIfSfz: [Int: Int] {
        if case .sfz(_, _, let defaults) = source { return defaults }
        return [:]
    }
}

/// One channel strip of the mixer: a layer's voices plus its own FX unit chain
/// (source → low shelf → mid parametric → high shelf → low-pass → compressor → drive → delay → reverb → master).
private final class Channel {
    let id: UUID
    var voices: [Voice] = []
    var fx: PianoPlayer.LayerFX
    var source: AVAudioSourceNode?
    var eqLow: AVAudioUnit?
    var eqMid: AVAudioUnit?
    var eqHigh: AVAudioUnit?
    var filter: AVAudioUnit?
    var comp: AVAudioUnit?
    var drive: AVAudioUnit?
    var delay: AVAudioUnit?
    var reverb: AVAudioUnit?
    /// Modulation oscillators, phases in cycles (0…1), advanced once per
    /// output frame for the whole channel: global mod-wheel tremolo (5 Hz),
    /// channel LFO (+ sample-and-hold value) and vibrato.
    var tremPhase: Double = 0
    var lfoPhase: Double = 0
    var lfoHold: Float = 0
    var lfoSeed: UInt32 = 0x9E37_79B9
    var vibPhase: Double = 0
    /// Per-block modulation buffers (fixed allocation; render never allocates).
    static let modCapacity = 8192
    let modAmp = UnsafeMutablePointer<Float>.allocate(capacity: Channel.modCapacity)
    let modPitch = UnsafeMutablePointer<Float>.allocate(capacity: Channel.modCapacity)
    let modVibrato = UnsafeMutablePointer<Float>.allocate(capacity: Channel.modCapacity)
    let modFilter = UnsafeMutablePointer<Float>.allocate(capacity: Channel.modCapacity)
    /// Mono: keys held on this channel, oldest first (note priority + return
    /// to a still-held note on release).
    var monoHeld: [(note: Int, velocity: Int)] = []
    /// Arpeggiator: notes in the pattern (stays after key-up while HOLD is on),
    /// physical keys down, step logic, timing (uptime ns) and the notes the
    /// current step is sounding.
    var arpHeld: [(note: Int, velocity: Int)] = []
    var arpKeysDown: Set<Int> = []
    var arpSequencer = ArpSequencer()
    var arpRunning = false
    var arpNext: UInt64 = 0
    var arpGateOff: UInt64 = 0
    var arpSounding: [Int] = []
    /// Last applied morph level multiplier (ramped per block to avoid zipper).
    var morphLevel: Float = 1
    /// MIDI CC state for SFZ region gates (drawbar positions), 0…127.
    /// Seeded from the program's <control> defaults; set via setLayerGateValue.
    var ccState: [Int: Int] = [:]
    /// Chorus (ensemble) state: stereo modulated-delay ring buffers (~93 ms),
    /// write cursor and LFO phase (advanced per frame when the chorus is on).
    var chorusL = [Float](repeating: 0, count: 8192)
    var chorusR = [Float](repeating: 0, count: 8192)
    var chorusWrite = 0
    var chorusPhase: Double = 0
    /// SoundFont layers: the sampler replaces the source node (its output feeds
    /// the same EQ/filter/comp/… strip). Bank loads once the engine is running.
    var sampler: AVAudioUnitSampler?
    var soundFontURL: URL?
    var bankLoaded = false
    /// Notes currently sounding in the sampler (keyboard markers; the sampler
    /// renders internally, so they don't appear in `voices`).
    var soundingNotes: Set<Int> = []
    /// Moog layers: the live mono voice rendered by the source node.
    var moog: MoogVoice?
    /// Notes sounding in the moog voice (keyboard markers).
    var moogNotes: Set<Int> = []

    init(id: UUID, fx: PianoPlayer.LayerFX) {
        self.id = id
        self.fx = fx
    }

    deinit {
        modAmp.deallocate()
        modPitch.deallocate()
        modVibrato.deallocate()
        modFilter.deallocate()
    }
}

/// Polyphonic player: decoded NSP strokes through AVAudioEngine (CoreAudio), MIDI in via
/// CoreMIDI. Local audition only — factory pianos are Clavia's audio; never extract or share.
public final class PianoPlayer {
    private(set) var layers: [Layer] = []
    /// IDs of the loaded layers, for UI sync.
    public var layerIDs: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return layers.map(\.id)
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var channels: [UUID: Channel] = [:]
    private var sustainPedal = false
    private var outRate: Double = 44_100
    /// Pitch bend in semitones (±2), from MIDI 0xE0. Multiplies every voice's rate.
    private var pitchBendSemis: Float = 0
    /// Wheel position −1…1 (each channel scales it by its own bend range).
    private var pitchBendNorm: Float = 0
    /// Tremolo depth 0…1, from MIDI CC1 (mod wheel). 5 Hz amplitude LFO.
    private var tremoloDepth: Float = 0
    /// Channel aftertouch 0…1 (MIDI 0xD0) and control pedal 0…1 (CC11/CC4) —
    /// morph sources for imported Nord programs.
    private var aftertouchValue: Float = 0
    private var controlPedalValue: Float = 0
    /// Master output gain 0…1, applied to the mixed buffers in the render callback.
    private var masterGain: Float = 1
    /// Extra "PA punch" boost in linear amplitude (1 = unity), from setMasterBoost dB.
    private var boostLinear: Float = 1

    /// Arpeggiator clock (created on first arp note) and its queue.
    private var arpClock: DispatchSourceTimer?
    private let arpQueue = DispatchQueue(label: "nordpiano.arp", qos: .userInteractive)

    deinit {
        arpClock?.cancel()
        // Release the output unit: abandoned running engines pile up IO units
        // in coreaudiod until new engines stall creating theirs.
        engine.stop()
        if let midiPort { MIDIPortDispose(midiPort) }
        if let midiClient { MIDIClientDispose(midiClient) }
    }

    /// FX settings for layers that have no channel yet (engine not started).
    private var pendingFX: [UUID: LayerFX] = [:]

    private var filterUnit: AVAudioUnit?
    private var compUnit: AVAudioUnit?
    private var delayUnit: AVAudioUnit?
    private var reverbUnit: AVAudioUnit?

    var onSoundingNotes: (@Sendable (Set<Int>) -> Void)?

    // MARK: - Devices

    /// Per-layer FX settings (all normalized 0…1 except EQ, which is −1…1 → ±12 dB).
    public struct LayerFX: Equatable, Codable {
        public var filterOn = false
        public var filterNorm: Double = 1
        public var compOn = false
        public var compAmount: Double = 0.3
        public var driveOn = false
        public var driveNorm: Double = 0.3
        public var driveMix: Double = 0.5
        public var delayOn = false
        public var delayTime: Double = 0.25 // seconds, 0…2
        public var delayFeedback: Double = 0.3
        public var delayMix: Double = 0.2
        public var reverbOn = false
        public var reverbMix: Double = 0.2
        public var reverbSize: Double = 0.3
        /// Attack time 0…1 (0 = instant). Cubic → 0…10 s so the fast end is fine.
        public var attackNorm: Double = 0
            /// Per-channel key-release level 0…1 (0.5 = default, 0 = silent).
        public var releaseGain: Double = 0.5
        /// Release time 0…1: exponential time constant 50 ms … 3 s (≈0.35 … 20 s
        /// to silence) for pads and strings.
        public var releaseTimeNorm: Double = 0
        /// Stereo position −1…1 (0 = center), equal-power.
        public var pan: Double = 0
        /// Chorus (ensemble): on/off, rate 0…1 → 0.2…4 Hz, depth 0…1.
        public var chorusOn = false
        public var chorusRate: Double = 0.3
        public var chorusDepth: Double = 0.5
        public var eqLow: Double = 0
        public var eqMid: Double = 0
        public var eqHigh: Double = 0
        // Synth-section modifiers (not shown for piano/organ channels):
        /// One-shot: notes play to the sample end even after key-up. Zones can
        /// also request this themselves (nsmp zoneIsOneShot flag).
        public var oneShot = false
        /// Mono mode: one voice at a time — new notes choke the previous one.
        public var monoOn = false
        /// Glide (portamento) time 0…1 → 0…400 ms, exponential approach. Mono only.
        public var glideNorm: Double = 0
        /// Channel LFO: depth 0…1, rate 0…1 → 0.05…20 Hz (SynthCurves.lfoHz),
        /// routed by `lfoDest` with waveform `lfoShape`.
        public var lfoDepth: Double = 0
        public var lfoRate: Double = 0.72 // ≈ 3.7 Hz
        /// Drawbar positions 0…8 for gated SFZ programs (organs), parallel to the
        /// layer's gate CC list (player.layerGateCCs). Empty = no drawbars.
        public var drawbars: [Double] = []
        /// Transpose in semitones (imported octave shifts arrive as ×12).
        public var octaveShift: Int = 0
        /// Filter resonance 0…1 (in-render SVF; SoundFont layers use the AU's).
        public var filterRes: Double = 0
        /// Filter envelope: amount −1…1 (±4 octaves of cutoff sweep; negative =
        /// inverted), attack/decay/release 0…1 on the Nord time curves
        /// (SynthCurves), sustain level 0…1.
        public var fltEnvAmt: Double = 0
        public var fltEnvAtk: Double = 0
        public var fltEnvDcy: Double = 0.3
        public var fltEnvSus: Double = 1
        public var fltEnvRls: Double = 0.2
        /// Extra velocity→level sensitivity 0…1 (program velocity morphs).
        public var velToLevel: Double = 0
        /// Morphs onto filter cutoff, −1…1 in cutoff-knob units (the delta the
        /// knob moves at full source): mod wheel, aftertouch, control pedal,
        /// and note-on velocity.
        public var wheelToCutoff: Double = 0
        public var atToCutoff: Double = 0
        public var pedalToCutoff: Double = 0
        public var velToCutoff: Double = 0
        /// Morphs onto layer level, relative to the layer's own level
        /// (−1 = silent at full source, +1 = double). Wheel/aftertouch/pedal.
        public var wheelToLevel: Double = 0
        public var atToLevel: Double = 0
        public var pedalToLevel: Double = 0
        /// Filter-envelope velocity 0…1: how much note-on velocity scales the
        /// envelope sweep (0 = fixed sweep, 1 = full sweep only at vel 127).
        public var fltEnvVel: Double = 0
        /// Filter model (SynthFilterType raw value), keyboard tracking 0…1
        /// (1 = cutoff follows pitch), and the LP+HP type's high-pass corner.
        public var filterType: Int = 0
        public var filterKeyTrack: Double = 0
        public var filterHPNorm: Double = 0
        /// Amp envelope decay (0…1, Nord decay curve) toward the sustain level
        /// 0…1 while the key is held. Sustain 1 = no decay stage (default).
        public var ampDecay: Double = 0.5
        public var ampSustain: Double = 1
        /// Channel LFO routing and waveform (SynthLfoDest / SynthLfoShape).
        public var lfoDest: Int = 0
        public var lfoShape: Int = 0
        /// Pitch vibrato: source (SynthVibratoMode), rate 0…1 (2…8 Hz), depth
        /// 0…1 (±0.5 semitone), fade-in seconds for the DELAY mode.
        public var vibMode: Int = 0
        public var vibRate: Double = 0.5
        public var vibDepth: Double = 0
        public var vibDelay: Double = 0
        /// Pitch-wheel range in semitones, up and down (0 = wheel ignored).
        public var bendUp: Int = 2
        public var bendDown: Int = 2
        /// Layer ignores the sustain pedal (Nord per-layer sustain switch off).
        public var ignoresSustain = false
        /// Keyboard zone: the layer only plays notes keyLow…keyHigh.
        public var keyLow: Int = 0
        public var keyHigh: Int = 127
        /// Mono variants: legato (no envelope retrigger while keys overlap)
        /// and note priority (SynthVoicePriority).
        public var legato = false
        public var voicePriority: Int = 0
        /// Arpeggiator: on, mode (SynthArpMode), direction (SynthArpDirection),
        /// octave range 1…4, rate 0…1 (1…30 steps/s), gate 0.05…1 of a step,
        /// and HOLD (pattern keeps running after the keys are released).
        public var arpOn = false
        public var arpMode: Int = 0
        public var arpDirection: Int = 0
        public var arpOctaves: Int = 1
        public var arpRate: Double = 0.61 // ≈ 8 steps/s (120 BPM 16ths)
        public var arpGate: Double = 0.5
        public var arpHold = false
        /// Saved-data version: 1 = original knob curves (filter 200 Hz…18 kHz,
        /// LFO 1…10 Hz), 2 = SynthCurves. Older data is migrated on decode.
        public var fxVersion: Int = 2
        public init() {}

        /// True when the program gives the mod wheel its own job, so the
        /// global CC1 tremolo stays off for this channel.
        var wheelMorphed: Bool {
            wheelToCutoff != 0 || wheelToLevel != 0 || vibMode == SynthVibratoMode.wheel.rawValue
        }

        /// Backward-compatible decoding: fields added after the first persisted
        /// version fall back to their defaults instead of failing the decode.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
                try c.decodeIfPresent(T.self, forKey: key) ?? fallback
            }
            let fresh = LayerFX()
            filterOn = try get(.filterOn, fresh.filterOn)
            filterNorm = try get(.filterNorm, fresh.filterNorm)
            compOn = try get(.compOn, fresh.compOn)
            compAmount = try get(.compAmount, fresh.compAmount)
            driveOn = try get(.driveOn, fresh.driveOn)
            driveNorm = try get(.driveNorm, fresh.driveNorm)
            driveMix = try get(.driveMix, fresh.driveMix)
            delayOn = try get(.delayOn, fresh.delayOn)
            delayTime = try get(.delayTime, fresh.delayTime)
            delayFeedback = try get(.delayFeedback, fresh.delayFeedback)
            delayMix = try get(.delayMix, fresh.delayMix)
            reverbOn = try get(.reverbOn, fresh.reverbOn)
            reverbMix = try get(.reverbMix, fresh.reverbMix)
            reverbSize = try get(.reverbSize, fresh.reverbSize)
            attackNorm = try get(.attackNorm, fresh.attackNorm)
            releaseGain = try get(.releaseGain, fresh.releaseGain)
            releaseTimeNorm = try get(.releaseTimeNorm, fresh.releaseTimeNorm)
            pan = try get(.pan, fresh.pan)
            chorusOn = try get(.chorusOn, fresh.chorusOn)
            chorusRate = try get(.chorusRate, fresh.chorusRate)
            chorusDepth = try get(.chorusDepth, fresh.chorusDepth)
            eqLow = try get(.eqLow, fresh.eqLow)
            eqMid = try get(.eqMid, fresh.eqMid)
            eqHigh = try get(.eqHigh, fresh.eqHigh)
            oneShot = try get(.oneShot, fresh.oneShot)
            monoOn = try get(.monoOn, fresh.monoOn)
            glideNorm = try get(.glideNorm, fresh.glideNorm)
            lfoDepth = try get(.lfoDepth, fresh.lfoDepth)
            lfoRate = try get(.lfoRate, fresh.lfoRate)
            drawbars = try get(.drawbars, fresh.drawbars)
            octaveShift = try get(.octaveShift, fresh.octaveShift)
            filterRes = try get(.filterRes, fresh.filterRes)
            fltEnvAmt = try get(.fltEnvAmt, fresh.fltEnvAmt)
            fltEnvAtk = try get(.fltEnvAtk, fresh.fltEnvAtk)
            fltEnvDcy = try get(.fltEnvDcy, fresh.fltEnvDcy)
            fltEnvSus = try get(.fltEnvSus, fresh.fltEnvSus)
            fltEnvRls = try get(.fltEnvRls, fresh.fltEnvRls)
            velToLevel = try get(.velToLevel, fresh.velToLevel)
            wheelToCutoff = try get(.wheelToCutoff, fresh.wheelToCutoff)
            atToCutoff = try get(.atToCutoff, fresh.atToCutoff)
            pedalToCutoff = try get(.pedalToCutoff, fresh.pedalToCutoff)
            velToCutoff = try get(.velToCutoff, fresh.velToCutoff)
            wheelToLevel = try get(.wheelToLevel, fresh.wheelToLevel)
            atToLevel = try get(.atToLevel, fresh.atToLevel)
            pedalToLevel = try get(.pedalToLevel, fresh.pedalToLevel)
            fltEnvVel = try get(.fltEnvVel, fresh.fltEnvVel)
            filterType = try get(.filterType, fresh.filterType)
            filterKeyTrack = try get(.filterKeyTrack, fresh.filterKeyTrack)
            filterHPNorm = try get(.filterHPNorm, fresh.filterHPNorm)
            ampDecay = try get(.ampDecay, fresh.ampDecay)
            ampSustain = try get(.ampSustain, fresh.ampSustain)
            lfoDest = try get(.lfoDest, fresh.lfoDest)
            lfoShape = try get(.lfoShape, fresh.lfoShape)
            vibMode = try get(.vibMode, fresh.vibMode)
            vibRate = try get(.vibRate, fresh.vibRate)
            vibDepth = try get(.vibDepth, fresh.vibDepth)
            vibDelay = try get(.vibDelay, fresh.vibDelay)
            bendUp = try get(.bendUp, fresh.bendUp)
            bendDown = try get(.bendDown, fresh.bendDown)
            ignoresSustain = try get(.ignoresSustain, fresh.ignoresSustain)
            keyLow = try get(.keyLow, fresh.keyLow)
            keyHigh = try get(.keyHigh, fresh.keyHigh)
            legato = try get(.legato, fresh.legato)
            voicePriority = try get(.voicePriority, fresh.voicePriority)
            arpOn = try get(.arpOn, fresh.arpOn)
            arpMode = try get(.arpMode, fresh.arpMode)
            arpDirection = try get(.arpDirection, fresh.arpDirection)
            arpOctaves = try get(.arpOctaves, fresh.arpOctaves)
            arpRate = try get(.arpRate, fresh.arpRate)
            arpGate = try get(.arpGate, fresh.arpGate)
            arpHold = try get(.arpHold, fresh.arpHold)
            // Version 1 stored the filter knob on 200·90^n Hz and the LFO rate
            // on 1+9n Hz: re-express both on the SynthCurves knobs.
            // Only values actually present are converted — a missing key
            // already holds the new-curve default.
            if try get(.fxVersion, 1) < 2 {
                if c.contains(.filterNorm) {
                    filterNorm = SynthCurves.cutoffNorm(hz: 200 * pow(90, filterNorm))
                }
                if c.contains(.lfoRate) {
                    lfoRate = min(1, max(0, log((1 + 9 * lfoRate) / 0.05) / log(400)))
                }
            }
            fxVersion = 2
        }
    }

    /// One CoreAudio output device (audio interface / built-in).
    public struct AudioDevice: Identifiable, Equatable {
        public let id: AudioDeviceID
        public let name: String
        public init(id: AudioDeviceID, name: String) { self.id = id; self.name = name }
    }

    /// One CoreMIDI source. Endpoint 0 = "all sources".
    public struct MidiInput: Identifiable, Equatable {
        public let id: MIDIEndpointRef
        public let name: String
        public init(id: MIDIEndpointRef, name: String) { self.id = id; self.name = name }
    }

    /// All output-capable audio devices.
    public static func audioOutputDevices() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard Self.outputChannelCount(id) > 0 else { return nil }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr else { return nil }
            return AudioDevice(id: id, name: (name?.takeRetainedValue() as String?) ?? "Device \(id)")
        }
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public private(set) var selectedAudioDevice: AudioDeviceID = kAudioDeviceUnknown

    /// Route output to a device (kAudioDeviceUnknown = system default). May be called
    /// before start(); it's applied when the engine comes up.
    public func setAudioOutputDevice(_ id: AudioDeviceID) throws {
        selectedAudioDevice = id
        guard id != kAudioDeviceUnknown else { return } // keep the system default
        guard engine.isRunning else { return }
        var dev = id
        let status = AudioUnitSetProperty(engine.outputNode.audioUnit!,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if ProcessInfo.processInfo.environment["NORD_DEBUG"] != nil {
            print("nordpiano: setAudioOutputDevice \(id) status \(status), engine running \(engine.isRunning)")
        }
        guard status == noErr else {
            throw NSError(domain: "nordpiano", code: 4, userInfo: [NSLocalizedDescriptionKey: "can't switch audio device (\(status))"])
        }
    }

    /// All MIDI sources currently on the system.
    public func midiInputs() -> [MidiInput] {
        (0..<MIDIGetNumberOfSources()).map { i in
            let s = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(s, kMIDIPropertyName, &name)
            return MidiInput(id: s, name: (name?.takeRetainedValue() as String?) ?? "Source \(s)")
        }
    }

    /// Endpoint to listen to; 0 = all sources.
    public private(set) var selectedMidiSource: MIDIEndpointRef = 0

    public func selectMidiSource(_ id: MIDIEndpointRef) {
        selectedMidiSource = id
        reconnectMidiSources()
    }

    private var lastSounding: Set<Int> = []

    private let releaseTau = 0.05 // key-up fade, ~60 dB in a third of a second
    private let mixHeadroom: Float = 0.35
    private let maxVoices = 128

    /// Single-piano convenience init (CLI).
    public convenience init(bytes: [UInt8]) throws {
        self.init()
        _ = try addLayer(bytes: bytes, id: UUID())
    }

    /// `midiInput: false` skips CoreMIDI entirely (tests: a connected keyboard
    /// must not play into players that are measuring their own output).
    public init(midiInput: Bool = true) { self.midiInput = midiInput }
    private let midiInput: Bool

    /// Add a piano to the layered mix; returns its index. Layers mix in parallel.
    @discardableResult
    public func addLayer(bytes: [UInt8], id: UUID, gain: Float = 1) throws -> Int {
        let dir = try readNspDirectory(bytes)
        let zones = readNspZones(bytes)
        guard !zones.isEmpty else { throw NspError.noDirectory }
        lock.lock()
        layers.append(Layer(id: id, gain: gain,
                            source: .piano(bytes: bytes, dir: dir, zones: zones)))
        let idx = layers.count - 1
        lock.unlock()
        // Engine graph mutation outside the lock: detach/connect can block on the
        // render thread, and the render callback takes this same lock.
        if engine.isRunning { attachChannel(id: id) }
        prewarm(idx)
        if ProcessInfo.processInfo.environment["NORD_DEBUG"] != nil {
            print("nordpiano: addLayer \(id.uuidString.prefix(8)), engine running \(engine.isRunning), channels \(self.channels.keys.count)")
        }
        return idx
    }

    /// Add an SFZ program to the layered mix; returns its index. The .sfz file
    /// is parsed now; its WAV regions decode lazily on the first matching note
    /// (and on the prewarm pass). Sample paths resolve against the file's
    /// directory, so the folder must stay put — SFZ layers are by-reference.
    @discardableResult
    public func addSfzLayer(url: URL, id: UUID, gain: Float = 1) throws -> Int {
        let program = SfzParser.parseFile(url) // #include directives expanded
        guard !program.regions.isEmpty else { throw SfzError.noRegions }
        lock.lock()
        layers.append(Layer(id: id, gain: gain,
                            source: .sfz(regions: program.regions,
                                         directory: url.deletingLastPathComponent(),
                                         controlDefaults: program.controlDefaults)))
        let idx = layers.count - 1
        lock.unlock()
        if engine.isRunning { attachChannel(id: id) }
        prewarm(idx)
        return idx
    }

    /// Add a SoundFont (`.sf2`/`.dls`) to the layered mix; returns its index.
    /// Nothing decodes here: the channel's AVAudioUnitSampler loads the bank
    /// once it's in the running graph (see attachChannel / loadSoundBank).
    @discardableResult
    public func addSoundFontLayer(url: URL, id: UUID, gain: Float = 1) throws -> Int {
        let head: [UInt8]
        if let handle = try? FileHandle(forReadingFrom: url) {
            head = [UInt8]((try? handle.read(upToCount: 12)) ?? Data())
            try? handle.close()
        } else { head = [] }
        guard isSoundFont(bytes: head) else { throw SoundFontError.notASoundFont }
        lock.lock()
        layers.append(Layer(id: id, gain: gain, source: .soundFont(url: url)))
        let idx = layers.count - 1
        lock.unlock()
        if engine.isRunning { attachChannel(id: id) }
        return idx
    }

    /// Add a Moog-style mono lead voice (NordMoog) to the layered mix; returns
    /// its index. Nothing to decode — the voice synthesizes in the channel's
    /// render callback. `patch` is the starting parameter set.
    @discardableResult
    public func addMoogLayer(id: UUID, gain: Float = 1, patch: MoogPatch = .lead) -> Int {
        lock.lock()
        layers.append(Layer(id: id, gain: gain, source: .moog))
        let idx = layers.count - 1
        lock.unlock()
        if engine.isRunning { attachChannel(id: id) }
        lock.lock()
        channels[id]?.moog?.patch = patch
        lock.unlock()
        return idx
    }

    /// Replace a moog layer's patch (preset load or panel edit).
    public func setMoogPatch(_ patch: MoogPatch, id: UUID) {
        lock.lock()
        channels[id]?.moog?.patch = patch
        lock.unlock()
    }

    /// The moog voice's current patch, if the layer is a moog layer.
    public func moogPatch(id: UUID) -> MoogPatch? {
        lock.lock(); defer { lock.unlock() }
        return channels[id]?.moog?.patch
    }

    /// Add a Nord Sample (`.nsmp3`/`.nsmp4`) to the layered mix; returns its index.
    /// Strokes decode lazily on the first note that references them.
    @discardableResult
    public func addSampleLayer(bytes: [UInt8], id: UUID, gain: Float = 1) throws -> Int {
        let identity = identifyNsmp(bytes)
        guard identity.recognized, !identity.legacy,
              let codec = identity.codec, codec == 3 || codec == 4 else { throw NsmpError.notASample }
        let zones = readNsmpZones(bytes)
        guard !zones.isEmpty else { throw NsmpError.badBlock("sample has no zones") }
        lock.lock()
        layers.append(Layer(id: id, gain: gain, source: .sample(bytes: bytes, zones: zones)))
        let idx = layers.count - 1
        lock.unlock()
        if engine.isRunning { attachChannel(id: id) }
        prewarm(idx)
        return idx
    }

    /// Decode every stroke of a freshly added layer on a background queue, so the
    /// first note in a zone doesn't pay the decode cost on the MIDI thread.
    /// The caches are lock-guarded; concurrent note-on decodes reuse them.
    private func prewarm(_ idx: Int) {
        lock.lock()
        guard idx < layers.count else { lock.unlock(); return }
        let layer = layers[idx]
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            switch layer.source {
            case .piano(let bytes, let dir, _):
                for stroke in dir.strokes {
                    _ = self.cachedOrDecodePiano(layer, stroke, bytes: bytes, dir: dir)
                }
            case .sample(let bytes, _):
                _ = self.cachedOrDecodeSample(layer, bytes: bytes)
            case .sfz(let regions, let directory, _):
                for index in regions.indices {
                    _ = self.cachedOrDecodeSfz(layer, region: regions[index],
                                               index: index, directory: directory)
                }
            case .soundFont:
                break // the sampler loads its own bank; nothing to pre-decode
            case .moog:
                break // synthesized live; nothing to pre-decode
            }
        }
    }

    /// MIDI notes of recorded samples across layers (keyboard markers). Sample zones
    /// use their absolute root keys — no piano offset.
    public var markers: [Int] {
        lock.lock(); defer { lock.unlock() }
        return layers.flatMap { layer -> [Int] in
            switch layer.source {
            case .piano(_, _, let zones):
                return zones.map { $0.rootNote + Nsp.rootOffset }
            case .sample(_, let zones):
                return zones.map(\.rootKey)
            case .sfz(let regions, _, _):
                return regions.map(\.rootKey)
            case .soundFont:
                return []
            case .moog:
                return []
            }
        }
    }

    public func removeLayer(id: UUID) {
        lock.lock()
        layers.removeAll { $0.id == id }
        let channel = channels.removeValue(forKey: id)
        lock.unlock()
        // Detach off the lock: engine graph changes can block on the render thread.
        if engine.isRunning, let channel { detach(channel: channel) }
    }

    public func setLayerGain(_ gain: Float, id: UUID) {
        lock.lock()
        if let i = layers.firstIndex(where: { $0.id == id }) { layers[i].gain = gain }
        if let sampler = channels[id]?.sampler { applySamplerGain(sampler, gain: gain) }
        lock.unlock()
    }

    /// Mute a layer: kills its sounding voices and blocks new ones.
    public func setLayerMuted(_ muted: Bool, id: UUID) {
        lock.lock()
        if let i = layers.firstIndex(where: { $0.id == id }) { layers[i].muted = muted }
        if muted, let channel = channels[id] {
            channel.voices.removeAll()
            channel.sampler?.sendController(123, withValue: 0, onChannel: 0) // all notes off
            channel.soundingNotes.removeAll()
        }
        lock.unlock()
    }


    // MARK: - Engine + FX chain (source → low-pass → compressor → reverb → mixer)

    public func start() throws {
        outRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2)!

        // Master bus FX: mainMixer → low-pass → compressor → delay → reverb → output.
        filterUnit = try makeEffect(kAudioUnitSubType_LowPassFilter)
        compUnit = try makeEffect(kAudioUnitSubType_DynamicsProcessor)
        delayUnit = try makeEffect(kAudioUnitSubType_Delay)
        reverbUnit = try makeEffect(kAudioUnitSubType_Reverb2)
        for unit in [filterUnit, compUnit, delayUnit, reverbUnit] { engine.attach(unit!) }
        engine.disconnectNodeOutput(engine.mainMixerNode) // drop the implicit mixer→output
        engine.connect(engine.mainMixerNode, to: filterUnit!, format: format)
        engine.connect(filterUnit!, to: compUnit!, format: format)
        engine.connect(compUnit!, to: delayUnit!, format: format)
        engine.connect(delayUnit!, to: reverbUnit!, format: format)
        engine.connect(reverbUnit!, to: engine.outputNode, format: format)

        // One channel strip per layer.
        for layer in layers { attachChannel(id: layer.id) }

        try engine.start()
        // Sound banks can only load into a running sampler.
        for channel in channels.values where channel.sampler != nil { loadSoundBank(channel) }

        // Defaults: everything neutral/bypassed.
        setFilter(enabled: false, cutoffHz: 18_000)
        setCompressor(amount: 0)
        setMasterDelay(enabled: false, timeSeconds: 0.25, feedback: 0.3, mix: 0.2)
        setReverb(mix: 0, decaySeconds: 1.8)

        // Re-apply the persisted output device now that the engine is live.
        if selectedAudioDevice != kAudioDeviceUnknown {
            try? setAudioOutputDevice(selectedAudioDevice)
        }

        if midiInput { try setupMIDI() }
        print("nordpiano: engine running at \(Int(outRate)) Hz — play; Ctrl-C to quit")
    }

    /// Set an AudioUnit parameter by its classic parameter ID (the hosted Apple
    /// units expose numeric-string identifiers, so identifier matching fails;
    /// the C API is unambiguous).
    private func setParam(_ unit: AVAudioUnit?, _ id: AudioUnitParameterID, _ value: Float) {
        guard let au = unit?.audioUnit else { return }
        AudioUnitSetParameter(au, id, kAudioUnitScope_Global, 0, value, 0)
    }

    private func setBypass(_ unit: AVAudioUnit?, _ bypass: Bool) {
        guard let unit else { return }
        var flag: UInt32 = bypass ? 1 : 0 // CoreAudio expects a 4-byte flag
        AudioUnitSetProperty(unit.audioUnit, kAudioUnitProperty_BypassEffect,
                             kAudioUnitScope_Global, 0, &flag, UInt32(MemoryLayout.size(ofValue: flag)))
    }

    /// FX insert unit, created synchronously (on-disk Apple units — fast).
    private func makeEffect(_ subtype: OSType) throws -> AVAudioUnit {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: subtype,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        var result: AVAudioUnit?
        var error: Error?
        let sem = DispatchSemaphore(value: 0)
        AVAudioUnit.instantiate(with: desc, options: []) { unit, err in
            result = unit; error = err; sem.signal()
        }
        sem.wait()
        if let error { throw error }
        guard let result else { throw NSError(domain: "nordpiano", code: 3) }
        return result
    }

    // MARK: - Channel strips (per-layer source + EQ + filter + comp + reverb)

    private func attachChannel(id: UUID) {
        if ProcessInfo.processInfo.environment["NORD_DEBUG"] != nil {
            print("nordpiano: attachChannel enter \(id.uuidString.prefix(8)), engine running \(engine.isRunning)")
        }
        guard channels[id] == nil else { return }
        let fx = pendingFX[id] ?? LayerFX()
        let format = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2)!
        let channel = Channel(id: id, fx: fx)
        do {
            channel.eqLow = try makeEffect(kAudioUnitSubType_LowShelfFilter)
            channel.eqMid = try makeEffect(kAudioUnitSubType_ParametricEQ)
            channel.eqHigh = try makeEffect(kAudioUnitSubType_HighShelfFilter)
            channel.filter = try makeEffect(kAudioUnitSubType_LowPassFilter)
            channel.comp = try makeEffect(kAudioUnitSubType_DynamicsProcessor)
            channel.drive = try makeEffect(kAudioUnitSubType_Distortion)
            channel.delay = try makeEffect(kAudioUnitSubType_Delay)
            channel.reverb = try makeEffect(kAudioUnitSubType_Reverb2)
        } catch {
            print("nordpiano: attachChannel \(id.uuidString.prefix(8)) FAILED: \(error)")
            return
        }
        let units = [channel.eqLow, channel.eqMid, channel.eqHigh,
                     channel.filter, channel.comp, channel.drive, channel.delay, channel.reverb]
        for unit in units { engine.attach(unit!) }
        if ProcessInfo.processInfo.environment["NORD_DEBUG"] != nil {
            print("nordpiano: attachChannel \(id.uuidString.prefix(8)) units ok")
        }

        // SoundFont layers: an AUSampler takes the source node's graph position
        // (same EQ/filter/comp/… strip downstream); notes reach it as MIDI
        // messages instead of our voice render.
        lock.lock()
        let layerSource = layers.first(where: { $0.id == id })?.source
        let soundFontURL: URL? = {
            if case .soundFont(let url) = layerSource { return url }
            return nil
        }()
        let isMoog = layerSource.map { if case .moog = $0 { return true }; return false } ?? false
        let layerGain = layers.first(where: { $0.id == id })?.gain ?? 1
        lock.unlock()
        if isMoog { channel.moog = MoogVoice(sampleRate: outRate) }
        if let url = soundFontURL {
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: channel.eqLow!, format: format)
            channel.sampler = sampler
            channel.soundFontURL = url
            applySamplerGain(sampler, gain: layerGain)
        } else {
        let source = AVAudioSourceNode(format: format) { [weak self] isSilence, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(channelID: id, intoL: outL, r: outR, frames: Int(frameCount))
            isSilence.pointee = false
            return noErr
        }
        channel.source = source
        engine.attach(source)
        engine.connect(source, to: channel.eqLow!, format: format)
        }
        engine.connect(channel.eqLow!, to: channel.eqMid!, format: format)
        engine.connect(channel.eqMid!, to: channel.eqHigh!, format: format)
        engine.connect(channel.eqHigh!, to: channel.filter!, format: format)
        engine.connect(channel.filter!, to: channel.comp!, format: format)
        engine.connect(channel.comp!, to: channel.drive!, format: format)
        engine.connect(channel.drive!, to: channel.delay!, format: format)
        engine.connect(channel.delay!, to: channel.reverb!, format: format)
        engine.connect(channel.reverb!, to: engine.mainMixerNode, format: format)
        channels[id] = channel
        // Seed the SFZ gate state from the program's <control> defaults.
        lock.lock()
        if let layer = layers.first(where: { $0.id == id }) {
            channel.ccState = layer.controlDefaultsIfSfz
        }
        lock.unlock()
        applyChannelFX(channel)
        if engine.isRunning { loadSoundBank(channel) }
    }

    /// Load the .sf2 bank into the channel's sampler (idempotent). AUSampler
    /// refuses bank loads before the engine runs, so channels created during
    /// start() are loaded right after engine.start() instead.
    private func loadSoundBank(_ channel: Channel) {
        guard let sampler = channel.sampler, let url = channel.soundFontURL, !channel.bankLoaded else { return }
        do {
            try sampler.loadSoundBankInstrument(at: url, program: 0,
                                                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            channel.bankLoaded = true
            // Select the loaded instrument explicitly: some banks stay silent
            // until channel 0 gets a program change naming its bank.
            sampler.sendProgramChange(0, bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                      bankLSB: UInt8(kAUSampler_DefaultBankLSB), onChannel: 0)
        } catch {
            print("nordpiano: sound bank load failed for \(url.lastPathComponent): \(error)")
        }
    }

    /// Channel strip gain for sampler layers: 0…1.5 linear → −90…+12 dB on the
    /// sampler's overall gain (voice layers apply theirs per note instead).
    private func applySamplerGain(_ sampler: AVAudioUnitSampler, gain: Float) {
        sampler.overallGain = gain <= 0.001 ? -90 : min(12, 20 * log10(gain))
    }

    private func detach(channel: Channel) {
        let nodes: [AVAudioNode] = [channel.source, channel.sampler, channel.eqLow, channel.eqMid, channel.eqHigh,
                                    channel.filter, channel.comp, channel.drive, channel.delay, channel.reverb].compactMap { $0 }
        for node in nodes { engine.disconnectNodeInput(node); engine.disconnectNodeOutput(node) }
        for node in nodes { engine.detach(node) }
    }

    // MARK: - SFZ gates (drawbars)

    /// Sorted CC numbers this layer's SFZ regions gate on — the drawbar
    /// controllers of an organ program (empty for pianos, Nord samples, and
    /// gate-less SFZ programs).
    public func layerGateCCs(id: UUID) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard let layer = layers.first(where: { $0.id == id }),
              case .sfz(let regions, _, _) = layer.source else { return [] }
        return Array(Set(regions.compactMap(\.gateCC))).sorted()
    }

    /// Current gate value (0…127) for a controller: the channel state if set,
    /// else the program's <control> default.
    public func layerGateValue(cc: Int, id: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let layer = layers.first(where: { $0.id == id }) else { return 0 }
        return channels[id]?.ccState[cc] ?? layer.controlDefaultsIfSfz[cc] ?? 0
    }

    /// Set a gate controller (0…127) — moves a drawbar. Affects notes played
    /// from now on (gating happens at note-on, like changing a registration
    /// between phrases).
    public func setLayerGateValue(_ value: Int, cc: Int, id: UUID) {
        lock.lock()
        if channels[id] == nil {
            let layer = layers.first(where: { $0.id == id })
            let ch = Channel(id: id, fx: pendingFX[id] ?? LayerFX())
            ch.ccState = layer?.controlDefaultsIfSfz ?? [:]
            channels[id] = ch
        }
        channels[id]?.ccState[cc] = min(127, max(0, value))
        lock.unlock()
    }

    /// Per-layer FX: EQ shelves/peaking, filter, compressor, reverb. All bypassed when off/flat.
    public func setLayerFX(_ fx: LayerFX, id: UUID) {
        lock.lock()
        pendingFX[id] = fx
        if let channel = channels[id] {
            channel.fx = fx
            applyChannelFX(channel)
        }
        lock.unlock()
    }

    public func layerFX(id: UUID) -> LayerFX {
        lock.lock(); defer { lock.unlock() }
        return channels[id]?.fx ?? pendingFX[id] ?? LayerFX()
    }

    private func applyChannelFX(_ channel: Channel) {
        let fx = channel.fx
        // 3-band EQ: low shelf @200 Hz, mid parametric @1 kHz, high shelf @10 kHz
        // (Apple's high-shelf cutoff bottoms out at 10 kHz).
        let db = Float(12) // −1…1 → ±12 dB
        setParam(channel.eqLow, kAULowShelfParam_CutoffFrequency, 200)
        setParam(channel.eqLow, kAULowShelfParam_Gain, Float(fx.eqLow) * db)
        setBypass(channel.eqLow, fx.eqLow == 0)
        // ParametricEQ/HighShelf constants aren't exported in Swift; parameter
        // IDs from Apple's AudioUnit headers: EQ center=0, Q=1, gain=2; shelf cutoff=0, gain=1.
        setParam(channel.eqMid, 0, 1_000) // center frequency
        setParam(channel.eqMid, 1, 1) // Q (unit minimum)
        setParam(channel.eqMid, 2, Float(fx.eqMid) * db) // gain
        setBypass(channel.eqMid, fx.eqMid == 0)
        setParam(channel.eqHigh, 0, 10_000) // cutoff (unit minimum)
        setParam(channel.eqHigh, 1, Float(fx.eqHigh) * db) // gain
        setBypass(channel.eqHigh, fx.eqHigh == 0)
        // Sample/piano layers filter in-render (resonant SVF per voice), so
        // their strip filter AU stays bypassed. SoundFont layers render inside
        // the sampler and never reach that code — the AU is their filter.
        if channel.sampler != nil {
            setParam(channel.filter, kLowPassParam_CutoffFrequency,
                     Float(min(18_000, SynthCurves.cutoffHz(fx.filterNorm))))
            setParam(channel.filter, kLowPassParam_Resonance, Float(fx.filterRes * 20))
            setBypass(channel.filter, !fx.filterOn)
        } else {
            setBypass(channel.filter, true)
        }
        applyCompressor(channel.comp, amount: fx.compOn ? fx.compAmount : 0)
        // Distortion: parameter IDs from Apple's AudioUnit headers —
        // SoftClipGain=14 (the drive amount), FinalMix=15 (wet/dry).
        setParam(channel.drive, 14, Float(fx.driveNorm * 20))
        setParam(channel.drive, 15, Float(min(100, max(0, fx.driveMix * 100))))
        setBypass(channel.drive, !fx.driveOn)
        // Delay mirrors the master-bus mapping (wet/dry=0, time=1, feedback=2).
        setParam(channel.delay, 0, Float(min(100, max(0, fx.delayMix * 100))))
        setParam(channel.delay, 1, Float(min(2, max(0, fx.delayTime))))
        setParam(channel.delay, 2, Float(min(100, max(0, fx.delayFeedback * 100))))
        setBypass(channel.delay, !fx.delayOn)
        setParam(channel.reverb, kReverb2Param_DryWetMix, Float(min(1, max(0, fx.reverbMix))) * 100)
        let decay = Float(min(20, max(0.1, 0.3 + fx.reverbSize * 6.7)))
        setParam(channel.reverb, kReverb2Param_DecayTimeAt0Hz, decay)
        setParam(channel.reverb, kReverb2Param_DecayTimeAtNyquist, decay)
        setBypass(channel.reverb, !fx.reverbOn)
    }

    /// DynamicsProcessor settings shared by master bus and channel strips.
    private func applyCompressor(_ unit: AVAudioUnit?, amount: Double) {
        let a = min(1, max(0, amount))
        setParam(unit, kDynamicsProcessorParam_Threshold, Float(-45 * a))
        setParam(unit, kDynamicsProcessorParam_OverallGain, Float(3 * a))
        setBypass(unit, a <= 0)
    }

    /// FILTER knob: 20 Hz…18 kHz. `enabled` is the Nord-style on/off.
    public func setFilter(enabled: Bool, cutoffHz: Double) {
        setParam(filterUnit, kLowPassParam_CutoffFrequency, Float(min(18_000, max(20, cutoffHz))))
        setBypass(filterUnit, !enabled)
    }

    /// COMPRESSOR amount 0…1: maps to threshold (0→−45 dB) with gentle makeup gain.
    public func setCompressor(amount: Double) {
        applyCompressor(compUnit, amount: amount)
    }

    /// REVERB: wet/dry mix 0…1 and room size mapped to decay time.
    public func setReverb(mix: Double, decaySeconds: Double) {
        let m = min(1, max(0, mix))
        setParam(reverbUnit, kReverb2Param_DryWetMix, Float(m * 100))
        setParam(reverbUnit, kReverb2Param_DecayTimeAt0Hz, Float(min(20, max(0.1, decaySeconds))))
        setParam(reverbUnit, kReverb2Param_DecayTimeAtNyquist, Float(min(20, max(0.1, decaySeconds))))
        setBypass(reverbUnit, m <= 0)
    }

    /// DELAY (echo): time 0…2 s, feedback 0…1 (0…100 %), wet/dry mix 0…1.
    /// Delay parameter IDs from Apple's AudioUnit headers: wet/dry=0, time=1, feedback=2.
    public func setMasterDelay(enabled: Bool, timeSeconds: Double, feedback: Double, mix: Double) {
        setParam(delayUnit, 0, Float(min(100, max(0, mix * 100))))
        setParam(delayUnit, 1, Float(min(2, max(0, timeSeconds))))
        setParam(delayUnit, 2, Float(min(100, max(0, feedback * 100))))
        setBypass(delayUnit, !enabled)
    }

    // MARK: - Recording (tap on the master chain tail → WAV)

    private var recordFile: AVAudioFile?
    private let recordLock = NSLock()
    /// Peak level (0…1) of each recorded buffer, for the UI waveform. ~10/sec.
    var onRecordLevel: (@Sendable (Float) -> Void)?

    public var isRecording: Bool {
        recordLock.lock(); defer { recordLock.unlock() }
        return recordFile != nil
    }

    /// Record the master bus (post-FX, exactly what the speakers get) to a 16-bit
    /// stereo WAV. The tap runs on the engine's worker thread, not the real-time
    /// render thread, so file I/O there is safe; playback is unaffected.
    public func startRecording(to url: URL) throws {
        guard engine.isRunning, let tail = reverbUnit else {
            throw NSError(domain: "nordpiano", code: 5, userInfo: [NSLocalizedDescriptionKey: "audio engine not running"])
        }
        stopRecording()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        recordLock.lock()
        recordFile = file
        recordLock.unlock()
        // Tap in the file's processing format so buffers arrive already converted.
        tail.installTap(onBus: 0, bufferSize: 4096, format: file.processingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.recordLock.lock()
            let f = self.recordFile
            self.recordLock.unlock()
            if let f { try? f.write(from: buffer) }
            // Report a per-buffer peak (strided — this is a meter, not an analysis).
            if let handler = self.onRecordLevel, let ch = buffer.int16ChannelData {
                let data = ch[0]
                let n = Int(buffer.frameLength) * Int(buffer.format.channelCount)
                var peak: Int32 = 0
                var i = 0
                while i < n {
                    let v = abs(Int32(data[i]))
                    if v > peak { peak = v }
                    i += 8
                }
                handler(Float(peak) / 32768)
            }
        }
    }

    // MARK: - Take playback (preview a recorded WAV through the main mixer, i.e.
    // the master FX chain processes it again on top of what's baked in)

    private var takeNode: AVAudioPlayerNode?
    /// Fired on a background thread when a take plays through to the end (not on
    /// early stop — the completion uses .dataPlayedBack).
    var onTakeEnded: (@Sendable () -> Void)?

    public var isPlayingTake: Bool { takeNode?.isPlaying ?? false }

    public func playTake(url: URL) throws {
        guard engine.isRunning else {
            throw NSError(domain: "nordpiano", code: 6, userInfo: [NSLocalizedDescriptionKey: "audio engine not running"])
        }
        stopTake()
        let file = try AVAudioFile(forReading: url)
        let node = AVAudioPlayerNode()
        engine.attach(node)
        // Route through the main mixer (multi-input) — NOT the output node, whose
        // single input bus is already taken by the master FX chain; forcing a
        // second connection onto it deadlocks the render graph.
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        takeNode = node
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.onTakeEnded?()
        }
        node.play()
    }

    public func stopTake() {
        guard let node = takeNode else { return }
        node.stop()
        engine.disconnectNodeOutput(node)
        engine.detach(node)
        takeNode = nil
    }

    public func stopRecording() {
        reverbUnit?.removeTap(onBus: 0)
        recordLock.lock()
        recordFile = nil
        recordLock.unlock()
    }

    // MARK: - MIDI

    private var midiClient: MIDIClientRef?
    private var midiPort: MIDIPortRef?
    private var connectedMidiSources: Set<MIDIEndpointRef> = []

    private func setupMIDI() throws {
        var client = MIDIClientRef()
        guard MIDIClientCreateWithBlock("nordpiano" as CFString, &client, { [weak self] note in
            // Re-scan connections when endpoints appear/vanish (devices attached
            // after launch would otherwise never be connected).
            if note.pointee.messageID == .msgObjectAdded || note.pointee.messageID == .msgObjectRemoved {
                self?.reconnectMidiSources()
            }
        }) == noErr else {
            throw NSError(domain: "nordpiano", code: 1, userInfo: [NSLocalizedDescriptionKey: "MIDIClientCreate failed"])
        }
        var port = MIDIPortRef()
        // Weak: an unretained pointer here outlived the player (MIDI kept
        // arriving after deallocation → use-after-free in noteOn).
        let callback: MIDIReadBlock = { [weak self] pktList, _ in
            self?.handlePackets(pktList)
        }
        guard MIDIInputPortCreateWithBlock(client, "in" as CFString, &port, callback) == noErr else {
            throw NSError(domain: "nordpiano", code: 2, userInfo: [NSLocalizedDescriptionKey: "MIDIInputPortCreate failed"])
        }
        midiClient = client
        midiPort = port
        reconnectMidiSources()
        if MIDIGetNumberOfSources() == 0 { print("nordpiano: warning — no MIDI sources found") }
        if ProcessInfo.processInfo.environment["NORD_DEBUG"] != nil {
            print("nordpiano: MIDI up, sources \(MIDIGetNumberOfSources()), selected \(selectedMidiSource), connected \(connectedMidiSources)")
        }
    }

    /// (Re)connect the selected source(s); called at start and on selection changes.
    private func reconnectMidiSources() {
        guard let port = midiPort else { return }
        for s in connectedMidiSources { MIDIPortDisconnectSource(port, s) }
        connectedMidiSources.removeAll()
        let wanted: [MIDIEndpointRef] = selectedMidiSource == 0
            ? (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }
            : [selectedMidiSource]
        for s in wanted where s != 0 {
            let ok = MIDIPortConnectSource(port, s, nil)
            if ok == noErr { connectedMidiSources.insert(s) }
            if ProcessInfo.processInfo.environment["NORD_DEBUG"] != nil {
                var name: Unmanaged<CFString>?
                MIDIObjectGetStringProperty(s, kMIDIPropertyName, &name)
                print("nordpiano: connect source \(s) \((name?.takeRetainedValue() as String?) ?? "?") -> \(ok == noErr ? "ok" : "FAIL \(ok)")")
            }
        }
    }

    private func handlePackets(_ list: UnsafePointer<MIDIPacketList>) {
        let count = list.pointee.numPackets
        let first = UnsafeMutableRawPointer(mutating: list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!)
        var ptr = first
        for _ in 0..<count {
            let pkt = ptr.assumingMemoryBound(to: MIDIPacket.self)
            let n = Int(pkt.pointee.length)
            withUnsafeMutablePointer(to: &pkt.pointee.data) { raw in
                raw.withMemoryRebound(to: UInt8.self, capacity: max(n, 1)) { bytes in
                    handleMidi(bytes: bytes, count: n)
                }
            }
            ptr = UnsafeMutableRawPointer(MIDIPacketNext(pkt))
        }
    }

    /// Short description of the last parsed MIDI message (footer readout).
    /// Fired on the MIDI thread for every channel-voice message; system
    /// real-time traffic (clock, active sensing) is skipped to avoid spam.
    var onMidiActivity: (@Sendable (String) -> Void)?

    /// Note number → "C4" style name (60 = C4).
    private func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[note % 12])\(note / 12 - 1)"
    }

    private func handleMidi(bytes b: UnsafePointer<UInt8>, count: Int) {
        if ProcessInfo.processInfo.environment["NORD_MIDI_LOG"] != nil {
            let hex = (0..<count).map { String(format: "%02X", b[$0]) }.joined(separator: " ")
            print("nordpiano: midi \(hex)")
        }
        var i = 0
        var runningStatus: UInt8 = 0
        while i < count {
            var status = b[i]
            if status & 0x80 != 0 {
                runningStatus = status
                i += 1
            } else {
                status = runningStatus
            }
            let channel = Int(status & 0x0F) + 1
            switch status & 0xF0 {
            case 0x90, 0x80:
                guard i + 1 < count else { return }
                let note = Int(b[i]), vel = Int(b[i + 1])
                i += 2
                if status & 0xF0 == 0x90 && vel > 0 {
                    noteOn(note, velocity: vel)
                    onMidiActivity?("Note On \(noteName(note)) (\(note)) vel \(vel) ch \(channel)")
                } else {
                    noteOff(note)
                    onMidiActivity?("Note Off \(noteName(note)) (\(note)) ch \(channel)")
                }
            case 0xA0: // polyphonic aftertouch
                guard i + 1 < count else { return }
                onMidiActivity?("Poly Aftertouch \(noteName(Int(b[i]))) = \(b[i + 1]) ch \(channel)")
                i += 2
            case 0xB0:
                guard i + 1 < count else { return }
                let cc = b[i], val = b[i + 1]
                i += 2
                if cc == 64 { sustain(val >= 64) }
                if cc == 1 { modWheel(Int(val)) } // modulation wheel → tremolo depth
                if cc == 11 || cc == 4 { controlPedal(Int(val)) } // expression / foot controller
                onMidiActivity?("CC \(cc) = \(val) ch \(channel)")
            case 0xC0: // program change: one data byte
                guard i < count else { return }
                onMidiActivity?("Program Change \(b[i]) ch \(channel)")
                i += 1
            case 0xD0: // channel aftertouch: one data byte
                guard i < count else { return }
                aftertouch(Int(b[i]))
                onMidiActivity?("Aftertouch \(b[i]) ch \(channel)")
                i += 1
            case 0xE0: // pitch bend: 14-bit value, center 8192
                guard i + 1 < count else { return }
                let v = Int(b[i]) | Int(b[i + 1]) << 7
                i += 2
                pitchBend((Float(v - 8192) / 8192) * 2)
                onMidiActivity?("Pitch Bend \(v - 8192) ch \(channel)")
            default:
                if status & 0xF8 == 0xF8 { i += 1 } else { i += min(2, count - i) }
            }
        }
    }

    // MARK: - Voices

    public func noteOn(_ note: Int, velocity: Int) {
        lock.lock()
        let snapshot = layers
        lock.unlock()
        if ProcessInfo.processInfo.environment["NORD_DEBUG"] != nil {
            print("nordpiano: noteOn \(note) vel \(velocity), layers \(snapshot.map { $0.id.uuidString.prefix(8) }), engine running \(engine.isRunning)")
        }
        var soundFontPlayed = false
        for layer in snapshot {
            if layer.muted { continue }
            lock.lock()
            let fx = channels[layer.id]?.fx ?? pendingFX[layer.id] ?? LayerFX()
            lock.unlock()
            // Keyboard zone (split): the layer only answers inside its range.
            guard note >= fx.keyLow && note <= fx.keyHigh else { continue }
            if case .soundFont = layer.source {
                lock.lock()
                let channel = channels[layer.id]
                channel?.soundingNotes.insert(note)
                lock.unlock()
                channel?.sampler?.startNote(UInt8(clamping: note), withVelocity: UInt8(clamping: velocity), onChannel: 0)
                soundFontPlayed = true
                continue
            }
            if case .moog = layer.source {
                lock.lock()
                let channel = channel(for: layer)
                if channel.moog == nil { channel.moog = MoogVoice(sampleRate: outRate) }
                channel.moogNotes.insert(note)
                channel.moog?.noteOn(note: note, velocity: velocity)
                lock.unlock()
                continue
            }
            if fx.arpOn {
                // Arpeggiator: the key joins the pattern; the arp clock plays it.
                lock.lock()
                let channel = channel(for: layer)
                if fx.arpHold && channel.arpKeysDown.isEmpty {
                    channel.arpHeld.removeAll() // HOLD: a fresh chord replaces the latched one
                }
                channel.arpKeysDown.insert(note)
                channel.arpHeld.removeAll { $0.note == note }
                channel.arpHeld.append((note, velocity))
                if !channel.arpRunning {
                    channel.arpRunning = true
                    channel.arpSequencer = ArpSequencer()
                    channel.arpNext = DispatchTime.now().uptimeNanoseconds // first step right away
                }
                lock.unlock()
                ensureArpClock()
                continue
            }
            if fx.monoOn {
                // Mono: remember the key; only the priority winner sounds.
                lock.lock()
                let channel = channel(for: layer)
                channel.monoHeld.removeAll { $0.note == note }
                channel.monoHeld.append((note, velocity))
                let winner = SynthVoicePriority(rawValue: fx.voicePriority)?.winner(channel.monoHeld)
                lock.unlock()
                guard winner?.note == note else { continue }
            }
            startVoices(layer, note: note, velocity: velocity, fx: fx)
        }
        if soundFontPlayed { notifySoundingNow() }
    }

    // MARK: - Arpeggiator clock

    /// Start the arp clock thread on first use: a 1 ms high-priority timer,
    /// outside the audio callback so starting a step (which may decode piano
    /// strokes) never runs on the render thread.
    private func ensureArpClock() {
        lock.lock()
        defer { lock.unlock() }
        guard arpClock == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: arpQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(250))
        timer.setEventHandler { [weak self] in self?.arpTick() }
        timer.resume()
        arpClock = timer
    }

    /// One clock tick: end gates that are due, then fire due steps.
    private func arpTick() {
        let now = DispatchTime.now().uptimeNanoseconds
        var starts: [(layer: Layer, note: Int, velocity: Int, fx: LayerFX)] = []
        lock.lock()
        for layer in layers {
            guard let channel = channels[layer.id], channel.arpRunning else { continue }
            let fx = channel.fx
            guard fx.arpOn, !channel.arpHeld.isEmpty, !layer.muted else {
                // Turned off, all keys up (no HOLD), or muted: stop cleanly.
                releaseArpNotes(channel)
                channel.arpRunning = false
                channel.arpHeld.removeAll()
                channel.arpKeysDown.removeAll()
                continue
            }
            if channel.arpGateOff != 0 && now >= channel.arpGateOff {
                releaseArpNotes(channel)
                channel.arpGateOff = 0
            }
            guard now >= channel.arpNext else { continue }
            releaseArpNotes(channel)
            let interval = UInt64(1e9 / SynthCurves.arpStepsPerSecond(fx.arpRate))
            let notes = channel.arpSequencer.next(
                held: channel.arpHeld,
                mode: SynthArpMode(rawValue: fx.arpMode) ?? .arp,
                direction: SynthArpDirection(rawValue: fx.arpDirection) ?? .up,
                octaves: fx.arpOctaves)
            channel.arpSounding = notes.map(\.note)
            channel.arpGateOff = now + UInt64(Double(interval) * min(0.98, max(0.05, fx.arpGate)))
            // Keep the grid; resync only if we fell more than a step behind.
            channel.arpNext = now - channel.arpNext > interval ? now + interval : channel.arpNext + interval
            for n in notes where (0...127).contains(n.note) {
                starts.append((layer, n.note, n.velocity, fx))
            }
        }
        lock.unlock()
        for s in starts { startVoices(s.layer, note: s.note, velocity: s.velocity, fx: s.fx) }
    }

    /// Release the voices the current arp step started. Caller holds `lock`.
    private func releaseArpNotes(_ channel: Channel) {
        guard !channel.arpSounding.isEmpty else { return }
        let notes = Set(channel.arpSounding)
        for i in channel.voices.indices
        where notes.contains(channel.voices[i].note) && !channel.voices[i].releasing && !channel.voices[i].oneShot {
            channel.voices[i].releasing = true
        }
        channel.arpSounding.removeAll()
    }

    /// The layer's channel, created on first use. Caller holds `lock`.
    private func channel(for layer: Layer) -> Channel {
        if let existing = channels[layer.id] { return existing }
        let ch = Channel(id: layer.id, fx: pendingFX[layer.id] ?? LayerFX())
        ch.ccState = layer.controlDefaultsIfSfz
        channels[layer.id] = ch
        return ch
    }

    /// Start `note` on one sample/piano layer: pick its strokes, build the
    /// voices (envelopes, filter, pitch) and hand them to the channel. In mono
    /// mode the sounding voice is choked first — glide starts from its pitch,
    /// and legato carries its envelopes over instead of retriggering.
    private func startVoices(_ layer: Layer, note: Int, velocity: Int, fx: LayerFX) {
        let picks = pickStrokes(layer, note: note, velocity: velocity)
        guard !picks.isEmpty else { return }
        // Mono hand-off, once per note (not per pick — an SFZ note with several
        // regions must not choke its own first region).
        var previous: Voice?
        if fx.monoOn {
            lock.lock()
            if let channel = channels[layer.id] {
                for i in channel.voices.indices where !channel.voices[i].releasing {
                    if previous == nil { previous = channel.voices[i] }
                    channel.voices[i].releasing = true
                    channel.voices[i].choke = true
                }
            }
            lock.unlock()
        }
        let legatoFrom = fx.monoOn && fx.legato ? previous : nil
        for picked in picks {
            let gain = Float(pow(10, -touchAttenuation(velocity) * picked.velTrack / 100)) * mixHeadroom * layer.gain * picked.gainScale
            var v = Voice(pcm: picked.stroke.pcm, rate: 1, gain: gain, note: note)
            v.oneShot = picked.oneShot || fx.oneShot
            // Attack: up to 10 s, cubic so the fast end stays fine (pads need
            // the long tail of the range).
            let attackSec = 10 * pow(fx.attackNorm, 3)
            if attackSec > 0.001 {
                v.env = 0
                v.attackStep = Float(1 / (attackSec * outRate))
            }
            // Decay toward sustain while held (Nord synth amp envelope).
            if fx.ampSustain < 1 {
                v.ampSus = Float(max(0, fx.ampSustain))
                // Decay time ≈ time to −60 dB.
                v.ampDecayCoef = Float(exp(-6.9 / (SynthCurves.decaySeconds(fx.ampDecay) * outRate)))
            }
            // Program velocity morph: extra touch sensitivity on top of the
            // sample's own dynamics (0 = the sample's native response).
            if fx.velToLevel > 0 {
                v.gain *= Float(pow(Double(velocity) / 127, 2 * fx.velToLevel))
            }
            // Filter envelope: per-voice ADSR sweeping the SVF cutoff.
            if fx.filterOn && fx.fltEnvAmt != 0 {
                func step(_ seconds: Double) -> Float { Float(1 / (max(0.0005, seconds) * outRate)) }
                v.fltAtkStep = step(SynthCurves.attackSeconds(fx.fltEnvAtk))
                v.fltDcyStep = fx.fltEnvDcy >= 1 ? 0
                    : step(SynthCurves.decaySeconds(fx.fltEnvDcy)) * Float(1 - fx.fltEnvSus)
                v.fltSus = fx.fltEnvDcy >= 1 ? 1 : Float(fx.fltEnvSus)
                v.fltRlsStep = step(SynthCurves.decaySeconds(fx.fltEnvRls))
                // Envelope velocity: harder hit = bigger sweep.
                v.fltEnvScale = Float(1 - fx.fltEnvVel + fx.fltEnvVel * Double(velocity) / 127)
            }
            // Velocity → cutoff morph: full delta at vel 127, none at 0.
            v.velCutoff = Float(fx.velToCutoff * Double(velocity) / 127)
            // Keyboard tracking around middle C.
            if fx.filterKeyTrack > 0 {
                v.keyTrackMul = Float(pow(2, Double(note - 60) / 12 * fx.filterKeyTrack))
            }
            let semitones = Double(note - picked.rootKey + fx.octaveShift) + Double(picked.cents) / 100
            v.rate = pow(2, semitones / 12) * (picked.stroke.sampleRate / outRate)
            if let previous {
                // Glide from wherever the previous note's pitch was.
                if fx.glideNorm > 0.01 {
                    v.currentRate = previous.currentRate > 0 ? previous.currentRate : previous.rate
                    v.glideCoef = 1 / (0.4 * fx.glideNorm * outRate)
                }
                // Legato: no retrigger — continue the envelopes where they were.
                if let from = legatoFrom {
                    v.env = from.env
                    v.attackStep = from.attackStep
                    v.fltEnv = from.fltEnv
                    v.fltStage = from.fltStage
                    v.age = from.age
                }
            }
            if let loop = picked.stroke.loop {
                v.hasLoop = true
                v.loopStart = Double(loop.start)
                v.loopEnd = Double(loop.start + loop.length)
                let db = picked.stroke.decayDbPerSecond
                if db > 0 {
                    v.loopDecayPerFrame = Float(pow(10, -db / 20 * (v.rate / picked.stroke.sampleRate)))
                }
            }
            lock.lock()
            let channel = channel(for: layer)
            if channel.voices.count >= maxVoices,
               let idx = channel.voices.firstIndex(where: { !$0.sustained && !$0.releasing }) {
                channel.voices[idx].releasing = true
                channel.voices[idx].env = 0 // stolen
            }
            channel.voices.append(v)
            lock.unlock()
        }
    }

    public func noteOff(_ note: Int) {
        lock.lock()
        var soundFontChanged = false
        // Mono channels whose released key was the sounding one while other
        // keys are still held: the priority winner takes over (no release).
        var monoReturns: [(id: UUID, note: Int, velocity: Int, fx: LayerFX)] = []
        for channel in channels.values {
            if let sampler = channel.sampler {
                sampler.stopNote(UInt8(clamping: note), onChannel: 0)
                soundFontChanged = channel.soundingNotes.remove(note) != nil || soundFontChanged
            }
            if channel.moog != nil {
                if channel.moogNotes.remove(note) != nil { channel.moog?.noteOff(note: note) }
                continue
            }
            let fx = channel.fx
            if fx.arpOn && channel.arpRunning {
                // Arp notes end on the arp's own gate, not on key-up.
                channel.arpKeysDown.remove(note)
                if !fx.arpHold { channel.arpHeld.removeAll { $0.note == note } }
                continue
            }
            if fx.monoOn, let idx = channel.monoHeld.firstIndex(where: { $0.note == note }) {
                let priority = SynthVoicePriority(rawValue: fx.voicePriority) ?? .last
                let wasSounding = priority.winner(channel.monoHeld)?.note == note
                channel.monoHeld.remove(at: idx)
                if wasSounding, let next = priority.winner(channel.monoHeld) {
                    monoReturns.append((channel.id, next.note, next.velocity, fx))
                    continue
                }
            }
            let holdByPedal = sustainPedal && !fx.ignoresSustain
            for i in channel.voices.indices
            where channel.voices[i].note == note && !channel.voices[i].releasing && !channel.voices[i].oneShot {
                if holdByPedal { channel.voices[i].sustained = true } else { channel.voices[i].releasing = true }
            }
        }
        let snapshot = monoReturns.isEmpty ? [] : layers
        lock.unlock()
        for ret in monoReturns {
            if let layer = snapshot.first(where: { $0.id == ret.id }) {
                startVoices(layer, note: ret.note, velocity: ret.velocity, fx: ret.fx)
            }
        }
        if soundFontChanged { notifySoundingNow() }
        // Key-release sample: the zone's flags==2 stroke, one-shot, riding on the
        // touch gain of the loudest just-released voice (the file has no release
        // velocity notion). Skipped while the pedal holds the note.
        guard !sustainPedal else { return }
        lock.lock()
        // Level follows the released voice's CURRENT effective gain (touch gain ×
        // envelope × any loop decay), not the note-on's initial gain — a note held
        // long enough to decay gets a proportionally quieter release thump.
        let releasedGain = channels.values.flatMap(\.voices)
            .filter { $0.note == note && $0.releasing }
            .map { $0.gain * $0.env }.max()
        lock.unlock()
        guard let releasedGain else { return }
        noteOnRelease(note, gain: releasedGain)
    }

    /// Spawn the key-release stroke for `note` as a one-shot voice on each piano
    /// layer; level = effective voice gain × the channel's own release knob.
    /// No attack ramp — the thud needs its transient.
    private func noteOnRelease(_ note: Int, gain: Float) {
        lock.lock()
        let snapshot = layers
        lock.unlock()
        for layer in snapshot {
            if layer.muted { continue }
            guard case .piano(let bytes, let dir, let zones) = layer.source,
                  let key = pianoKey(zones, midi: note),
                  let stroke = releaseStrokeFor(dir, zone: key.zone) else { continue }
            lock.lock()
            let scale = Float((channels[layer.id]?.fx ?? pendingFX[layer.id] ?? LayerFX()).releaseGain)
            lock.unlock()
            let cached = cachedOrDecodePiano(layer, stroke, bytes: bytes, dir: dir)
            var v = Voice(pcm: cached.pcm, rate: 1, gain: gain * scale, note: note)
            let semitones = Double(note - zones[key.zone].rootNote - Nsp.rootOffset)
            v.rate = pow(2, semitones / 12) * (cached.sampleRate / outRate)
            lock.lock()
            if let channel = channels[layer.id] {
                channel.voices.append(v)
            }
            lock.unlock()
        }
    }

    /// Pitch wheel, in semitones (±2). Applies live to every sounding voice.
    public func pitchBend(_ semitones: Float) {
        lock.lock()
        pitchBendSemis = min(2, max(-2, semitones))
        pitchBendNorm = pitchBendSemis / 2
        // Samplers get the raw 14-bit wheel (their own bend range applies).
        let wheel = UInt16(clamping: Int(8192 + pitchBendSemis / 2 * 8191))
        for channel in channels.values { channel.sampler?.sendPitchBend(wheel, onChannel: 0) }
        lock.unlock()
    }

    /// Mod wheel (CC1), 0…127 → tremolo depth 0…1.
    public func modWheel(_ value: Int) {
        lock.lock()
        tremoloDepth = Float(value) / 127
        let cc = UInt8(clamping: value)
        for channel in channels.values { channel.sampler?.sendController(1, withValue: cc, onChannel: 0) }
        lock.unlock()
    }

    /// Channel aftertouch, 0…127 → morph source 0…1 (also forwarded to samplers).
    public func aftertouch(_ value: Int) {
        lock.lock()
        aftertouchValue = Float(min(127, max(0, value))) / 127
        for channel in channels.values { channel.sampler?.sendPressure(UInt8(clamping: value), onChannel: 0) }
        lock.unlock()
    }

    /// Control/expression pedal (CC11 or CC4), 0…127 → morph source 0…1.
    public func controlPedal(_ value: Int) {
        lock.lock()
        controlPedalValue = Float(min(127, max(0, value))) / 127
        for channel in channels.values { channel.sampler?.sendController(11, withValue: UInt8(clamping: value), onChannel: 0) }
        lock.unlock()
    }

    /// Sounding-set notification driven by MIDI rather than the render loop —
    /// SoundFont channels have no source node, so without this the on-screen
    /// keyboard would never light for sampler-only setups.
    private func notifySoundingNow() {
        lock.lock()
        var all: Set<Int> = []
        for ch in channels.values {
            all.formUnion(ch.voices.map(\.note))
            all.formUnion(ch.soundingNotes)
            all.formUnion(ch.moogNotes)
        }
        let changed = all != lastSounding
        if changed { lastSounding = all }
        lock.unlock()
        if changed, let handler = onSoundingNotes {
            DispatchQueue.main.async { handler(all) }
        }
    }

    public func sustain(_ down: Bool) {
        lock.lock()
        sustainPedal = down
        for channel in channels.values {
            channel.sampler?.sendController(64, withValue: down ? 127 : 0, onChannel: 0)
        }
        if !down {
            for channel in channels.values {
                for i in channel.voices.indices where channel.voices[i].sustained {
                    channel.voices[i].sustained = false
                    channel.voices[i].releasing = true
                }
            }
        }
        lock.unlock()
    }

    /// Global output volume 0…1, applied at the final mix.
    public func setMasterVolume(_ volume: Float) {
        lock.lock()
        masterGain = min(1, max(0, volume))
        lock.unlock()
    }

    /// Output boost 0…+12 dB (0 = unity, the default). Multiplies master volume
    /// at the final mix — the "PA punch" control. Watch clipping when layering.
    public func setMasterBoost(dB: Float) {
        lock.lock()
        boostLinear = pow(10, min(12, max(0, dB)) / 20)
        lock.unlock()
    }

    /// Pick the stroke + root key for a note on one layer: piano zones route through
    /// the layer table and velocity floors; sample zones match key range + velocity
    /// range directly and name their stroke by global id.
    /// One matched voice source: the decoded stroke, its root key, fine-tune in
    /// cents, a per-region gain scale (SFZ `volume`), one-shot behavior, and
    /// velocity tracking (1 = full touch response, 0 = organ-style fixed level).
    private typealias Pick = (stroke: CachedStroke, rootKey: Int, cents: Int,
                              gainScale: Float, oneShot: Bool, velTrack: Double)

    /// All strokes matching a note/velocity. Pianos and Nord samples have exactly
    /// one zone per key/velocity; SFZ regions layer — every match plays.
    private func pickStrokes(_ layer: Layer, note: Int, velocity: Int) -> [Pick] {
        switch layer.source {
        case .piano(let bytes, let dir, let zones):
            guard let key = pianoKey(zones, midi: note),
                  let stroke = strokeFor(dir, zone: key.zone, velocity: velocity) else { return [] }
            return [(cachedOrDecodePiano(layer, stroke, bytes: bytes, dir: dir),
                     zones[key.zone].rootNote + Nsp.rootOffset, 0, 1, false, 1)]
        case .sample(let bytes, let zones):
            guard let zone = nsmpZone(for: note, velocity: velocity, in: zones) else { return [] }
            let strokes = cachedOrDecodeSample(layer, bytes: bytes)
            guard let stroke = strokes[zone.globalID] else { return [] }
            return [(stroke, zone.rootKey, 0, 1, zone.zoneIsOneShot != 0, 1)]
        case .sfz(let regions, let directory, _):
            lock.lock()
            let ccState = channels[layer.id]?.ccState ?? layer.controlDefaultsIfSfz
            lock.unlock()
            return regions.indices.compactMap { index in
                let region = regions[index]
                guard region.matches(note: note, velocity: velocity) else { return nil }
                if let cc = region.gateCC, !region.gatePasses(ccValue: ccState[cc] ?? 0) { return nil }
                guard let stroke = cachedOrDecodeSfz(layer, region: region, index: index,
                                                     directory: directory) else { return nil }
                return (stroke, region.rootKey, region.tuneCents,
                        Float(pow(10, region.volumeDb / 20)), region.oneShot,
                        region.ampVelTrack / 100)
            }
        case .soundFont:
            return [] // the channel's sampler handles its own notes
        case .moog:
            return [] // the channel's moog voice handles its own notes
        }
    }

    /// Decode an SFZ region's WAV (mono/stereo, any rate — the voice render
    /// resamples), cached per region index. Loop points come from the region's
    /// loop_start/loop_end opcodes, falling back to the WAV's smpl chunk when
    /// the region loops. Missing/unreadable samples are skipped silently (the
    /// rest of the program still plays).
    private func cachedOrDecodeSfz(_ layer: Layer, region: SfzRegion, index: Int,
                                   directory: URL) -> CachedStroke? {
        lock.lock(); let cached = layer.sampleCache[index]; lock.unlock()
        if let cached { return cached }
        // SFZ sample paths are often Windows-style; normalize for macOS.
        let relative = region.sample.replacingOccurrences(of: "\\", with: "/")
        let url = directory.appendingPathComponent(relative)
        guard let bytes = try? Data(contentsOf: url),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: capacity),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var pcm: [[Float]] = []
        for ch in 0..<min(2, channelCount) {
            pcm.append(Array(UnsafeBufferPointer(start: channels[ch], count: frames)))
        }
        if pcm.count == 1, channelCount > 1 {
            // More channels than we took (shouldn't happen with min(2,…)); keep mono.
        }
        var loop: (start: Int, length: Int)?
        if let start = region.loopStart, let end = region.loopEnd, end > start {
            loop = (start, end - start + 1)
        } else if region.loopMode == .continuous || region.loopMode == .sustain {
            loop = readWavLoop([UInt8](bytes))
        }
        let stroke = CachedStroke(pcm: pcm, sampleRate: file.fileFormat.sampleRate,
                                  loop: loop, decayDbPerSecond: 0)
        lock.lock()
        if let i = layers.firstIndex(where: { $0.id == layer.id }) {
            layers[i].sampleCache[index] = stroke
        }
        lock.unlock()
        return stroke
    }

    private func cachedOrDecodePiano(_ layer: Layer, _ stroke: NspStroke,
                                     bytes: [UInt8], dir: NspDirectory) -> CachedStroke {
        lock.lock(); let cached = layer.cache[stroke.index]; lock.unlock()
        if let cached { return cached }
        let decoded = (try? decodeNspStroke(bytes, dir: dir, stroke: stroke)) ?? []
        let pcm = decoded.map { ch in ch.map { Float($0) / 32768 } }
        // Piano files store loop decay as a linear multiplier applied Nsp.envelopeRate
        // times a second; convert to dB/s the render loop expects (0 = hold forever).
        var decayDbPerSecond = 0.0
        if let decay = stroke.loopDecay, decay > 0, decay < 1 {
            decayDbPerSecond = -20 * log10(decay) * Double(Nsp.envelopeRate)
        }
        let result = CachedStroke(pcm: pcm, sampleRate: Double(Nsp.sampleRate),
                                  loop: stroke.loop,
                                  decayDbPerSecond: decayDbPerSecond)
        lock.lock()
        if let idx = layers.firstIndex(where: { $0.id == layer.id }) {
            layers[idx].cache[stroke.index] = result
        }
        lock.unlock()
        return result
    }

    /// Decode the whole sample on first use, cached per layer, keyed by stroke global id.
    /// The NW1 decode is fast (a 20-stroke file decodes in <100 ms); sample files are small.
    private func cachedOrDecodeSample(_ layer: Layer, bytes: [UInt8]) -> [Int: CachedStroke] {
        lock.lock(); let done = layer.sampleDecoded; lock.unlock()
        if done { return layer.sampleCache }
        let decoded = (try? decodeNsmpStrokes(bytes)) ?? []
        var byID: [Int: CachedStroke] = [:]
        for item in decoded {
            let s = item.stroke
            byID[Int(s.globalID)] = CachedStroke(
                pcm: item.channels.map { ch in ch.map { Float($0) / 32768 } },
                sampleRate: Double(s.sampleRate),
                loop: s.loop,
                decayDbPerSecond: s.loopDecayDbPerSecond)
        }
        lock.lock()
        if let idx = layers.firstIndex(where: { $0.id == layer.id }) {
            layers[idx].sampleCache = byID
            layers[idx].sampleDecoded = true
        }
        lock.unlock()
        return byID
    }

    // MARK: - Render (audio thread, one source-node callback per channel)

    private func render(channelID: UUID, intoL outL: UnsafeMutablePointer<Float>, r outR: UnsafeMutablePointer<Float>, frames: Int) {
        for frame in 0..<frames {
            outL[frame] = 0
            outR[frame] = 0
        }
        // Voices are rendered IN PLACE under the lock: taking them out for the mix
        // created a window where noteOff/sustain found an empty voice list and
        // marked nothing, and the put-back reinserted the voice with releasing=false
        // — the stuck-note bug. Decoding happens outside this lock, so hold times
        // stay sub-millisecond.
        lock.lock()
        guard let channel = channels[channelID] else { lock.unlock(); return }
        let master = masterGain * boostLinear
        let fx = channel.fx
        // Pitch wheel through this layer's own range (up/down may differ).
        let bendSemis = pitchBendNorm >= 0 ? pitchBendNorm * Float(fx.bendUp) : pitchBendNorm * Float(fx.bendDown)
        let bendMul = Float(pow(2, bendSemis / 12))
        let morph = MorphSources(wheel: tremoloDepth, aftertouch: aftertouchValue,
                                 pedal: controlPedalValue)
        let mod = fillModulation(channel, fx: fx, morph: morph, frames: frames)
        if let moog = channel.moog {
            // Moog layer: the voice renders mono into L; copy to R. The FX
            // strip (EQ/filter/…), chorus and pan below still apply downstream.
            let gain = (layers.first(where: { $0.id == channelID })?.gain ?? 1) * master
            moog.render(into: UnsafeMutableBufferPointer(start: outL, count: frames), frames: frames)
            for frame in 0..<frames {
                outL[frame] *= gain
                outR[frame] = outL[frame]
            }
        } else {
        renderVoices(&channel.voices, master: master, bendMul: bendMul, mod: mod,
                     releaseTau: releaseTau * pow(60, fx.releaseTimeNorm),
                     fx: fx, morph: morph,
                     intoL: outL, r: outR, frames: frames)
        }
        // Level morphs (wheel/aftertouch/pedal), ramped across the block.
        let targetLevel = Float(max(0, 1 + fx.wheelToLevel * Double(morph.wheel)
            + fx.atToLevel * Double(morph.aftertouch) + fx.pedalToLevel * Double(morph.pedal)))
        if targetLevel != 1 || channel.morphLevel != 1 {
            let start = channel.morphLevel
            let step = (targetLevel - start) / Float(max(1, frames))
            for frame in 0..<frames {
                let g = start + step * Float(frame + 1)
                outL[frame] *= g
                outR[frame] *= g
            }
            channel.morphLevel = targetLevel
        }

        // Ensemble (chorus): two modulated delay taps under the dry signal,
        // L/R a quarter-cycle apart for width. Then the pan knob (equal-power).
        if fx.chorusOn {
            applyChorus(channel: channel, rate: fx.chorusRate, depth: fx.chorusDepth,
                        intoL: outL, r: outR, frames: frames)
        }
        if fx.pan != 0 {
            let angle = (fx.pan + 1) * .pi / 4 // −1…1 → 0…π/2
            let gainL = Float(cos(angle))
            let gainR = Float(sin(angle))
            for frame in 0..<frames {
                outL[frame] *= gainL
                outR[frame] *= gainR
            }
        }

        // Aggregate across channels; notify only when the sounding set changes.
        var all: Set<Int> = []
        for ch in channels.values {
            all.formUnion(ch.voices.map(\.note))
            all.formUnion(ch.soundingNotes)
            all.formUnion(ch.moogNotes)
        }
        let changed = all != lastSounding
        if changed { lastSounding = all }
        lock.unlock()

        if changed {
            let handler = onSoundingNotes
            DispatchQueue.main.async { handler?(all) }
        }
    }

    /// Advance the channel's modulation oscillators across the block, once per
    /// frame for the whole channel, into its mod buffers: amplitude (global
    /// mod-wheel tremolo + LFO→amp), pitch (LFO→pitch), vibrato, and filter
    /// (LFO→cutoff, octaves). Caller holds `lock`.
    private func fillModulation(_ channel: Channel, fx: LayerFX, morph: MorphSources,
                                frames: Int) -> ModBlock {
        var mod = ModBlock(amp: channel.modAmp, pitch: channel.modPitch, vibrato: channel.modVibrato,
                           filter: channel.modFilter, capacity: Channel.modCapacity)
        let n = min(frames, Channel.modCapacity)
        // The classic CC1 tremolo stays off when the program gives the wheel a job.
        let trem = fx.wheelMorphed ? 0 : tremoloDepth
        let lfoDepth = Float(max(0, fx.lfoDepth))
        let dest = SynthLfoDest(rawValue: fx.lfoDest) ?? .amp
        let shape = SynthLfoShape(rawValue: fx.lfoShape) ?? .triangle
        let vibSource: Float = switch SynthVibratoMode(rawValue: fx.vibMode) ?? .off {
        case .off: 0
        case .on, .delayed: 1
        case .wheel: morph.wheel
        case .aftertouch: morph.aftertouch
        case .pedal: morph.pedal
        }
        let vibSemis = Float(SynthCurves.vibratoSemitones(fx.vibDepth)) * vibSource
        mod.ampActive = trem > 0 || (lfoDepth > 0 && dest == .amp)
        mod.pitchActive = lfoDepth > 0 && dest == .pitch
        mod.filterActive = lfoDepth > 0 && dest == .filter
        mod.vibratoActive = vibSemis > 0
        if fx.vibMode == SynthVibratoMode.delayed.rawValue {
            mod.vibratoDelayFrames = Float(max(0, fx.vibDelay) * outRate)
        }
        guard mod.ampActive || mod.pitchActive || mod.filterActive || mod.vibratoActive else { return mod }
        let tremStep = 5 / outRate
        let lfoStep = SynthCurves.lfoHz(fx.lfoRate) / outRate
        let vibStep = SynthCurves.vibratoHz(fx.vibRate) / outRate
        let twoPi = 2 * Double.pi
        for f in 0..<n {
            var amp: Float = 1
            if trem > 0 {
                amp *= 1 - 0.5 * trem * (1 + Float(sin(twoPi * channel.tremPhase)))
                channel.tremPhase += tremStep
                if channel.tremPhase >= 1 { channel.tremPhase -= 1 }
            }
            if lfoDepth > 0 {
                let w = shape.value(channel.lfoPhase, hold: channel.lfoHold)
                switch dest {
                case .amp: amp *= 1 - 0.5 * lfoDepth * (1 + w)
                case .pitch: mod.pitch[f] = w * lfoDepth * 2 // ±2 semitones at full depth
                case .filter: mod.filter[f] = w * lfoDepth * 3 // ±3 octaves at full depth
                }
                channel.lfoPhase += lfoStep
                if channel.lfoPhase >= 1 {
                    channel.lfoPhase -= 1
                    // Sample-and-hold: new random level each cycle (xorshift — no
                    // allocation or syscalls on the audio thread).
                    channel.lfoSeed ^= channel.lfoSeed << 13
                    channel.lfoSeed ^= channel.lfoSeed >> 17
                    channel.lfoSeed ^= channel.lfoSeed << 5
                    channel.lfoHold = Float(channel.lfoSeed) / Float(UInt32.max) * 2 - 1
                }
            }
            if vibSemis > 0 {
                mod.vibrato[f] = vibSemis * Float(sin(twoPi * channel.vibPhase))
                channel.vibPhase += vibStep
                if channel.vibPhase >= 1 { channel.vibPhase -= 1 }
            }
            mod.amp[f] = amp
        }
        return mod
    }

    /// Mix one block of voices into the output, mutating `voices` in place:
    /// finished voices are removed, survivors keep their advanced position.
    /// Caller must hold `lock` (noteOff/sustain mark these same structs).
    private func renderVoices(_ voices: inout [Voice], master: Float, bendMul: Float,
                              mod: ModBlock, releaseTau: Double, fx: LayerFX, morph: MorphSources,
                              intoL outL: UnsafeMutablePointer<Float>, r outR: UnsafeMutablePointer<Float>, frames: Int) {
        let releaseStep = Float(exp(-1 / (releaseTau * outRate)))
        let chokeStep = Float(exp(-1 / (0.004 * outRate)))
        let rate = Float(outRate)
        let last = mod.capacity - 1
        // Per-voice resonant filter (ZDF SVF, Nord filter types). Cutoff follows
        // the knob (moved by the wheel/aftertouch/pedal/velocity morphs) ×
        // keyboard tracking × the filter envelope × the LFO, recomputed every
        // 32 frames — per-frame tan() per voice is wasted precision.
        let filterOn = fx.filterOn
        let filterType = fx.filterType
        let filterRes = Float(fx.filterRes)
        let hpHz = Float(SynthCurves.cutoffHz(fx.filterHPNorm))
        let envSweep = Float(4 * fx.fltEnvAmt) // octaves of envelope sweep (sign = direction)
        let blockNorm = Float(fx.filterNorm + fx.wheelToCutoff * Double(morph.wheel)
            + fx.atToCutoff * Double(morph.aftertouch) + fx.pedalToCutoff * Double(morph.pedal))
        func updateFilter(_ v: inout Voice, lfoOctaves: Float) {
            let norm = min(1, max(0, blockNorm + v.velCutoff))
            let base = Float(SynthCurves.cutoffHz(Double(norm)))
            let hz = base * v.keyTrackMul * exp2(envSweep * v.fltEnv * v.fltEnvScale + lfoOctaves)
            v.filter.update(hz: min(20_000, max(10, hz)), hpHz: hpHz, res: filterRes,
                            type: filterType, rate: rate)
        }
        var vi = voices.startIndex
        while vi < voices.endIndex {
            var v = voices[vi]
            let count = v.pcm[0].count
            let stereo = v.pcm.count == 2
            var frame = 0
            var alive = true
            if filterOn { updateFilter(&v, lfoOctaves: mod.filterActive ? mod.filter[0] : 0) }

            while frame < frames {
                let mi = min(frame, last)
                // Amp envelope. Release wins over attack: a key let go mid-attack
                // must fade, not keep climbing (it used to stall at a constant
                // level forever on looped samples).
                if v.releasing {
                    v.attackStep = 0
                    v.env *= v.choke ? chokeStep : releaseStep
                    if v.env < 1e-3 { alive = false; break }
                } else if v.attackStep > 0 {
                    v.env += v.attackStep
                    if v.env >= 1 { v.env = 1; v.attackStep = 0 }
                } else if v.ampDecayCoef < 1 {
                    v.env = v.ampSus + (v.env - v.ampSus) * v.ampDecayCoef
                    if v.ampSus <= 0 && v.env < 1e-4 { alive = false; break }
                }
                if Int(v.pos) >= count {
                    if v.hasLoop {
                        while v.pos >= v.loopEnd { v.pos -= v.loopEnd - v.loopStart }
                    } else { alive = false; break }
                }
                if v.hasLoop && v.pos >= v.loopEnd {
                    v.pos -= v.loopEnd - v.loopStart
                }
                let p0 = Int(v.pos)
                let frac = Float(v.pos - Double(p0))
                let p1 = min(p0 + 1, count - 1)
                var l = v.pcm[0][p0] + (v.pcm[0][p1] - v.pcm[0][p0]) * frac
                var r = stereo ? v.pcm[1][p0] + (v.pcm[1][p1] - v.pcm[1][p0]) * frac : l
                if filterOn {
                    // Filter first (pre amp env, like a synth voice).
                    l = v.filter.process(l, left: true, type: filterType)
                    r = stereo ? v.filter.process(r, left: false, type: filterType) : l
                }
                var g = v.env * v.gain * master
                if mod.ampActive { g *= mod.amp[mi] }
                l *= g
                r = stereo ? r * g : l
                outL[frame] += l
                outR[frame] += r
                // Filter envelope + cutoff, at control rate (every 32 frames).
                if filterOn && frame & 31 == 0 {
                    if v.releasing {
                        v.fltEnv = max(0, v.fltEnv - v.fltRlsStep * 32)
                    } else if v.fltStage == 0 {
                        v.fltEnv += v.fltAtkStep * 32
                        if v.fltEnv >= 1 { v.fltEnv = 1; v.fltStage = 1 }
                    } else if v.fltStage == 1 {
                        v.fltEnv -= v.fltDcyStep * 32
                        if v.fltEnv <= v.fltSus { v.fltEnv = v.fltSus; v.fltStage = 2 }
                    }
                    updateFilter(&v, lfoOctaves: mod.filterActive ? mod.filter[mi] : 0)
                }
                var step = (v.currentRate > 0 ? v.currentRate : v.rate) * Double(bendMul)
                if mod.pitchActive || mod.vibratoActive {
                    var semis: Float = mod.pitchActive ? mod.pitch[mi] : 0
                    if mod.vibratoActive {
                        let fade = mod.vibratoDelayFrames > 0 ? min(1, Float(v.age) / mod.vibratoDelayFrames) : 1
                        semis += mod.vibrato[mi] * fade
                    }
                    step *= Double(exp2(semis / 12))
                }
                v.pos += step
                v.age += 1
                if v.currentRate > 0 {
                    v.currentRate += (v.rate - v.currentRate) * v.glideCoef
                    if abs(v.currentRate - v.rate) < 0.002 * v.rate { v.currentRate = 0 } // arrived
                }
                if v.hasLoop && v.pos >= v.loopStart && v.pos < v.loopEnd {
                    v.gain *= v.loopDecayPerFrame
                }
                frame += 1
            }
            if alive {
                voices[vi] = v
                vi = voices.index(after: vi)
            } else {
                voices.remove(at: vi)
            }
        }
    }

    /// Ensemble chorus on the channel's mixed output: a short modulated delay
    /// (10–18 ms) summed with the dry signal, LFO rate 0.2…4 Hz. The right
    /// channel's LFO runs a quarter-cycle ahead for stereo width. Runs on the
    /// audio thread under `lock` — no allocation, linear-interpolated reads.
    private func applyChorus(channel: Channel, rate: Double, depth: Double,
                             intoL outL: UnsafeMutablePointer<Float>, r outR: UnsafeMutablePointer<Float>, frames: Int) {
        let n = channel.chorusL.count
        let hz = 0.2 + rate * 3.8
        let phaseStep = 2 * Double.pi * hz / outRate
        let wet: Float = 0.3
        // Base 10 ms + up to 8 ms of LFO swing (depth 0 flattens the modulation).
        let baseFrames = 0.010 * outRate
        let swingFrames = 0.008 * depth * outRate
        for frame in 0..<frames {
            channel.chorusPhase += phaseStep
            let modL = (1 + sin(channel.chorusPhase)) * 0.5
            let modR = (1 + sin(channel.chorusPhase + .pi / 2)) * 0.5
            let delayL = baseFrames + swingFrames * modL
            let delayR = baseFrames + swingFrames * modR
            let write = channel.chorusWrite
            channel.chorusL[write] = outL[frame]
            channel.chorusR[write] = outR[frame]
            outL[frame] = outL[frame] * (1 - wet) + readRing(channel.chorusL, from: write, delay: delayL) * wet
            outR[frame] = outR[frame] * (1 - wet) + readRing(channel.chorusR, from: write, delay: delayR) * wet
            channel.chorusWrite = (write + 1) & (n - 1)
        }
    }

    /// Linear-interpolated read `delay` frames behind the write cursor in a
    /// power-of-two ring buffer.
    private func readRing(_ buf: [Float], from write: Int, delay: Double) -> Float {
        let n = buf.count
        let read = Double(write) - delay
        let i0 = Int(read) & (n - 1)
        let i1 = (i0 + 1) & (n - 1)
        let frac = Float(read - Double(Int(read)))
        return buf[i0] + (buf[i1] - buf[i0]) * frac
    }
}

public extension PianoPlayer {
    var soundingNotesHandler: (@Sendable (Set<Int>) -> Void)? {
        get { onSoundingNotes }
        set { onSoundingNotes = newValue }
    }
    var recordLevelHandler: (@Sendable (Float) -> Void)? {
        get { onRecordLevel }
        set { onRecordLevel = newValue }
    }
    var takeEndedHandler: (@Sendable () -> Void)? {
        get { onTakeEnded }
        set { onTakeEnded = newValue }
    }
    var midiActivityHandler: (@Sendable (String) -> Void)? {
        get { onMidiActivity }
        set { onMidiActivity = newValue }
    }
}
