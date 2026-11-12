import Foundation
import CoreAudio
import CoreMIDI
import AVFAudio
import AudioToolbox
import NordPianoCore

/// Real-time piano voice: one decoded stroke being played.
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

/// What a layer plays: a piano library (`.npno`, NSP/CNSP codec) or a Nord Sample
/// (`.nsmp3`/`.nsmp4`, NW1 codec 3/4). Sample strokes decode lazily on first note,
/// cached per layer like piano strokes.
enum LayerSource {
    case piano(bytes: [UInt8], dir: NspDirectory, zones: [NspZone])
    case sample(bytes: [UInt8], zones: [NsmpZone])
}

struct Layer {
    let id: URL
    var gain: Float
    var muted = false
    var cache: [Int: CachedStroke] = [:]
    var source: LayerSource
    /// Sample strokes decoded so far (keyed by global id); `sampleDecoded` marks the
    /// whole-file decode having run (a stroke may legitimately be absent).
    var sampleCache: [Int: CachedStroke] = [:]
    var sampleDecoded = false
}

/// One channel strip of the mixer: a layer's voices plus its own FX unit chain
/// (source → low shelf → mid parametric → high shelf → low-pass → compressor → drive → delay → reverb → master).
private final class Channel {
    let id: URL
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

    init(id: URL, fx: PianoPlayer.LayerFX) {
        self.id = id
        self.fx = fx
    }
}

/// Polyphonic player: decoded NSP strokes through AVAudioEngine (CoreAudio), MIDI in via
/// CoreMIDI. Local audition only — factory pianos are Clavia's audio; never extract or share.
public final class PianoPlayer {
    private(set) var layers: [Layer] = []
    /// URLs of the loaded layers, for UI sync.
    public var layerIDs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return layers.map(\.id)
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var channels: [URL: Channel] = [:]
    private var sustainPedal = false
    private var outRate: Double = 44_100
    /// Master output gain 0…1, applied to the mixed buffers in the render callback.
    private var masterGain: Float = 1
    /// Extra "PA punch" boost in linear amplitude (1 = unity), from setMasterBoost dB.
    private var boostLinear: Float = 1

    /// FX settings for layers that have no channel yet (engine not started).
    private var pendingFX: [URL: LayerFX] = [:]

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
        /// Attack time 0…1 (0 = instant). Squared → 0…300 ms so the fast end is fine.
        public var attackNorm: Double = 0
            /// Per-channel key-release level 0…1 (0.5 = default, 0 = silent).
        public var releaseGain: Double = 0.5
        public var eqLow: Double = 0
        public var eqMid: Double = 0
        public var eqHigh: Double = 0
        public init() {}
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
        _ = try addLayer(bytes: bytes, id: URL(fileURLWithPath: "piano.npno"))
    }

    public init() {}

    /// Add a piano to the layered mix; returns its index. Layers mix in parallel.
    @discardableResult
    public func addLayer(bytes: [UInt8], id: URL, gain: Float = 1) throws -> Int {
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
            print("nordpiano: addLayer \(id.lastPathComponent), engine running \(engine.isRunning), channels \(self.channels.keys.map { $0.lastPathComponent })")
        }
        return idx
    }

    /// Add a Nord Sample (`.nsmp3`/`.nsmp4`) to the layered mix; returns its index.
    /// Strokes decode lazily on the first note that references them.
    @discardableResult
    public func addSampleLayer(bytes: [UInt8], id: URL, gain: Float = 1) throws -> Int {
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
            }
        }
    }

    public func removeLayer(id: URL) {
        lock.lock()
        layers.removeAll { $0.id == id }
        let channel = channels.removeValue(forKey: id)
        lock.unlock()
        // Detach off the lock: engine graph changes can block on the render thread.
        if engine.isRunning, let channel { detach(channel: channel) }
    }

    public func setLayerGain(_ gain: Float, id: URL) {
        lock.lock()
        if let i = layers.firstIndex(where: { $0.id == id }) { layers[i].gain = gain }
        lock.unlock()
    }

    /// Mute a layer: kills its sounding voices and blocks new ones.
    public func setLayerMuted(_ muted: Bool, id: URL) {
        lock.lock()
        if let i = layers.firstIndex(where: { $0.id == id }) { layers[i].muted = muted }
        if muted, let channel = channels[id] { channel.voices.removeAll() }
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

        // Defaults: everything neutral/bypassed.
        setFilter(enabled: false, cutoffHz: 18_000)
        setCompressor(amount: 0)
        setMasterDelay(enabled: false, timeSeconds: 0.25, feedback: 0.3, mix: 0.2)
        setReverb(mix: 0, decaySeconds: 1.8)

        // Re-apply the persisted output device now that the engine is live.
        if selectedAudioDevice != kAudioDeviceUnknown {
            try? setAudioOutputDevice(selectedAudioDevice)
        }

        try setupMIDI()
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

    private func attachChannel(id: URL) {
        if ProcessInfo.processInfo.environment["NORD_DEBUG"] != nil {
            print("nordpiano: attachChannel enter \(id.lastPathComponent), engine running \(engine.isRunning)")
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
            print("nordpiano: attachChannel \(id.lastPathComponent) FAILED: \(error)")
            return
        }
        let units = [channel.eqLow, channel.eqMid, channel.eqHigh,
                     channel.filter, channel.comp, channel.drive, channel.delay, channel.reverb]
        for unit in units { engine.attach(unit!) }
        if ProcessInfo.processInfo.environment["NORD_DEBUG"] != nil {
            print("nordpiano: attachChannel \(id.lastPathComponent) units ok")
        }

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
        engine.connect(channel.eqLow!, to: channel.eqMid!, format: format)
        engine.connect(channel.eqMid!, to: channel.eqHigh!, format: format)
        engine.connect(channel.eqHigh!, to: channel.filter!, format: format)
        engine.connect(channel.filter!, to: channel.comp!, format: format)
        engine.connect(channel.comp!, to: channel.drive!, format: format)
        engine.connect(channel.drive!, to: channel.delay!, format: format)
        engine.connect(channel.delay!, to: channel.reverb!, format: format)
        engine.connect(channel.reverb!, to: engine.mainMixerNode, format: format)
        channels[id] = channel
        applyChannelFX(channel)
    }

    private func detach(channel: Channel) {
        let nodes: [AVAudioNode] = [channel.source, channel.eqLow, channel.eqMid, channel.eqHigh,
                                    channel.filter, channel.comp, channel.drive, channel.delay, channel.reverb].compactMap { $0 }
        for node in nodes { engine.disconnectNodeInput(node); engine.disconnectNodeOutput(node) }
        for node in nodes { engine.detach(node) }
    }

    /// Per-layer FX: EQ shelves/peaking, filter, compressor, reverb. All bypassed when off/flat.
    public func setLayerFX(_ fx: LayerFX, id: URL) {
        lock.lock()
        pendingFX[id] = fx
        if let channel = channels[id] {
            channel.fx = fx
            applyChannelFX(channel)
        }
        lock.unlock()
    }

    public func layerFX(id: URL) -> LayerFX {
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
        // Filter / compressor / reverb mirror the master-bus mappings.
        setParam(channel.filter, kLowPassParam_CutoffFrequency,
                 Float(min(18_000, max(20, 200 * pow(90, fx.filterNorm)))))
        setBypass(channel.filter, !fx.filterOn)
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
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: MIDIReadBlock = { pktList, _ in
            let me = Unmanaged<PianoPlayer>.fromOpaque(ctx).takeUnretainedValue()
            me.handlePackets(pktList)
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
            switch status & 0xF0 {
            case 0x90, 0x80:
                guard i + 1 < count else { return }
                let note = Int(b[i]), vel = Int(b[i + 1])
                i += 2
                if status & 0xF0 == 0x90 && vel > 0 { noteOn(note, velocity: vel) } else { noteOff(note) }
            case 0xB0:
                guard i + 1 < count else { return }
                let cc = b[i], val = b[i + 1]
                i += 2
                if cc == 64 { sustain(val >= 64) }
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
            print("nordpiano: noteOn \(note) vel \(velocity), layers \(snapshot.map { $0.id.lastPathComponent }), engine running \(engine.isRunning)")
        }
        for layer in snapshot {
            if layer.muted { continue }
            guard let picked = pickStroke(layer, note: note, velocity: velocity) else { continue }

            let gain = Float(pow(10, -touchAttenuation(velocity) / 100)) * mixHeadroom * layer.gain
            var v = Voice(pcm: picked.stroke.pcm, rate: 1, gain: gain, note: note)
            // Per-channel attack ramp (0 = instant). Release samples skip it —
            // the hammer-fall thud needs its transient.
            lock.lock()
            let fx = channels[layer.id]?.fx ?? pendingFX[layer.id] ?? LayerFX()
            lock.unlock()
            let attackSec = 0.3 * fx.attackNorm * fx.attackNorm
            if attackSec > 0.001 {
                v.env = 0
                v.attackStep = Float(1 / (attackSec * outRate))
            }
            let semitones = Double(note - picked.rootKey)
            v.rate = pow(2, semitones / 12) * (picked.stroke.sampleRate / outRate)
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
            let channel = channels[layer.id] ?? {
                let ch = Channel(id: layer.id, fx: pendingFX[layer.id] ?? LayerFX())
                channels[layer.id] = ch
                return ch
            }()
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
        for channel in channels.values {
            for i in channel.voices.indices where channel.voices[i].note == note && !channel.voices[i].releasing {
                if sustainPedal { channel.voices[i].sustained = true } else { channel.voices[i].releasing = true }
            }
        }
        lock.unlock()
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

    public func sustain(_ down: Bool) {
        lock.lock()
        sustainPedal = down
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
    private func pickStroke(_ layer: Layer, note: Int, velocity: Int) -> (stroke: CachedStroke, rootKey: Int)? {
        switch layer.source {
        case .piano(let bytes, let dir, let zones):
            guard let key = pianoKey(zones, midi: note),
                  let stroke = strokeFor(dir, zone: key.zone, velocity: velocity) else { return nil }
            return (cachedOrDecodePiano(layer, stroke, bytes: bytes, dir: dir),
                    zones[key.zone].rootNote + Nsp.rootOffset)
        case .sample(let bytes, let zones):
            guard let zone = nsmpZone(for: note, velocity: velocity, in: zones) else { return nil }
            let strokes = cachedOrDecodeSample(layer, bytes: bytes)
            guard let stroke = strokes[zone.globalID] else { return nil }
            return (stroke, zone.rootKey)
        }
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

    private func render(channelID: URL, intoL outL: UnsafeMutablePointer<Float>, r outR: UnsafeMutablePointer<Float>, frames: Int) {
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
        renderVoices(&channel.voices, master: master, intoL: outL, r: outR, frames: frames)

        // Aggregate across channels; notify only when the sounding set changes.
        var all: Set<Int> = []
        for ch in channels.values { all.formUnion(ch.voices.map(\.note)) }
        let changed = all != lastSounding
        if changed { lastSounding = all }
        lock.unlock()

        if changed {
            let handler = onSoundingNotes
            DispatchQueue.main.async { handler?(all) }
        }
    }

    /// Mix one block of voices into the output, mutating `voices` in place:
    /// finished voices are removed, survivors keep their advanced position.
    /// Caller must hold `lock` (noteOff/sustain mark these same structs).
    private func renderVoices(_ voices: inout [Voice], master: Float, intoL outL: UnsafeMutablePointer<Float>, r outR: UnsafeMutablePointer<Float>, frames: Int) {
        let releaseStep = Float(exp(-1 / (releaseTau * outRate)))
        var vi = voices.startIndex
        while vi < voices.endIndex {
            var v = voices[vi]
            let count = v.pcm[0].count
            let stereo = v.pcm.count == 2
            var frame = 0
            var alive = true

            while frame < frames {
                if v.attackStep > 0 {
                    v.env += v.attackStep
                    if v.env >= 1 { v.env = 1; v.attackStep = 0 }
                }
                if v.releasing {
                    v.env *= releaseStep
                    if v.env < 1e-3 { alive = false; break }
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
                let l = (v.pcm[0][p0] + (v.pcm[0][p1] - v.pcm[0][p0]) * frac) * v.env * v.gain * master
                let r = stereo
                    ? (v.pcm[1][p0] + (v.pcm[1][p1] - v.pcm[1][p0]) * frac) * v.env * v.gain * master
                    : l
                outL[frame] += l
                outR[frame] += r
                v.pos += v.rate
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
}

public extension PianoPlayer {
    var soundingNotesHandler: (@Sendable (Set<Int>) -> Void)? {
        get { onSoundingNotes }
        set { onSoundingNotes = newValue }
    }
}
