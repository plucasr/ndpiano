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
    var loopStart: Int? // nil = one-shot; loop runs to the end of the audio
    var decayDbPerSecond: Double
}

struct Layer {
    let id: URL
    var gain: Float
    var cache: [Int: CachedStroke] = [:]
    var piano: (bytes: [UInt8], dir: NspDirectory, zones: [NspZone])
}

/// One channel strip of the mixer: a layer's voices plus its own FX unit chain
/// (source → low shelf → mid parametric → high shelf → low-pass → compressor → reverb → master).
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

    /// FX settings for layers that have no channel yet (engine not started).
    private var pendingFX: [URL: LayerFX] = [:]

    private var filterUnit: AVAudioUnit?
    private var compUnit: AVAudioUnit?
    private var reverbUnit: AVAudioUnit?

    var onSoundingNotes: (@Sendable (Set<Int>) -> Void)?

    // MARK: - Devices

    /// Per-layer FX settings (all normalized 0…1 except EQ, which is −1…1 → ±12 dB).
    public struct LayerFX: Equatable, Codable {
        public var filterOn = false
        public var filterNorm: Double = 1
        public var compOn = false
        public var compAmount: Double = 0.3
        public var reverbOn = false
        public var reverbMix: Double = 0.2
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
        guard engine.isRunning else { return }
        var dev = id
        let status = AudioUnitSetProperty(engine.outputNode.audioUnit!,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
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
        layers.append(Layer(id: id, gain: gain, piano: (bytes: bytes, dir: dir, zones: zones)))
        let idx = layers.count - 1
        if engine.isRunning { attachChannel(id: id) }
        lock.unlock()
        return idx
    }

    /// MIDI notes of recorded samples across layers (keyboard markers).
    public var markers: [Int] {
        lock.lock(); defer { lock.unlock() }
        return layers.flatMap { $0.piano.zones.map { $0.rootNote + Nsp.rootOffset } }
    }

    public func removeLayer(id: URL) {
        lock.lock()
        layers.removeAll { $0.id == id }
        if engine.isRunning { detachChannel(id: id) }
        channels[id] = nil
        lock.unlock()
    }

    public func setLayerGain(_ gain: Float, id: URL) {
        lock.lock()
        if let i = layers.firstIndex(where: { $0.id == id }) { layers[i].gain = gain }
        lock.unlock()
    }


    // MARK: - Engine + FX chain (source → low-pass → compressor → reverb → mixer)

    public func start() throws {
        outRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2)!

        // Master bus FX: mainMixer → low-pass → compressor → reverb → output.
        filterUnit = try makeEffect(kAudioUnitSubType_LowPassFilter)
        compUnit = try makeEffect(kAudioUnitSubType_DynamicsProcessor)
        reverbUnit = try makeEffect(kAudioUnitSubType_Reverb2)
        for unit in [filterUnit, compUnit, reverbUnit] { engine.attach(unit!) }
        engine.disconnectNodeOutput(engine.mainMixerNode) // drop the implicit mixer→output
        engine.connect(engine.mainMixerNode, to: filterUnit!, format: format)
        engine.connect(filterUnit!, to: compUnit!, format: format)
        engine.connect(compUnit!, to: reverbUnit!, format: format)
        engine.connect(reverbUnit!, to: engine.outputNode, format: format)

        // One channel strip per layer.
        for layer in layers { attachChannel(id: layer.id) }

        try engine.start()

        // Defaults: everything neutral/bypassed.
        setFilter(enabled: false, cutoffHz: 18_000)
        setCompressor(amount: 0)
        setReverb(mix: 0, decaySeconds: 1.8)

        // Re-apply the persisted output device now that the engine is live.
        if selectedAudioDevice != kAudioDeviceUnknown {
            try? setAudioOutputDevice(selectedAudioDevice)
        }

        try setupMIDI()
        print("nordpiano: engine running at \(Int(outRate)) Hz — play; Ctrl-C to quit")
    }

    private func param(_ unit: AVAudioUnit?, _ identifier: String) -> AUParameter? {
        unit?.auAudioUnit.parameterTree?.allParameters.first {
            $0.identifier.localizedCaseInsensitiveContains(identifier)
        }
    }

    private func setBypass(_ unit: AVAudioUnit?, _ bypass: Bool) {
        guard let unit else { return }
        var flag = bypass
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
            channel.reverb = try makeEffect(kAudioUnitSubType_Reverb2)
        } catch { return }
        let units = [channel.eqLow, channel.eqMid, channel.eqHigh,
                     channel.filter, channel.comp, channel.reverb]
        for unit in units { engine.attach(unit!) }

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
        engine.connect(channel.comp!, to: channel.reverb!, format: format)
        engine.connect(channel.reverb!, to: engine.mainMixerNode, format: format)
        channels[id] = channel
        applyChannelFX(channel)
    }

    private func detachChannel(id: URL) {
        guard let channel = channels[id] else { return }
        let nodes: [AVAudioNode] = [channel.source, channel.eqLow, channel.eqMid, channel.eqHigh,
                                    channel.filter, channel.comp, channel.reverb].compactMap { $0 }
        for node in nodes { engine.disconnectNodeInput(node); engine.disconnectNodeOutput(node) }
        for node in nodes { engine.detach(node) }
        channels[id] = nil
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
        let db = { (v: Double) in AUValue(v * 12) } // −1…1 → ±12 dB
        // 3-band EQ: low shelf @200 Hz, mid parametric @1 kHz, high shelf @6 kHz.
        param(channel.eqLow, "gain")?.value = db(fx.eqLow)
        param(channel.eqLow, "cutoff")?.value = 200
        setBypass(channel.eqLow, fx.eqLow == 0)
        param(channel.eqMid, "center")?.value = 1_000
        param(channel.eqMid, "q")?.value = 0.8
        param(channel.eqMid, "gain")?.value = db(fx.eqMid)
        setBypass(channel.eqMid, fx.eqMid == 0)
        param(channel.eqHigh, "gain")?.value = db(fx.eqHigh)
        param(channel.eqHigh, "cutoff")?.value = 6_000
        setBypass(channel.eqHigh, fx.eqHigh == 0)
        // Filter / compressor / reverb mirror the master-bus mappings.
        param(channel.filter, "cutoff")?.value = AUValue(min(18_000, max(20, 200 * pow(90, fx.filterNorm))))
        setBypass(channel.filter, !fx.filterOn)
        let a = min(1, max(0, fx.compAmount))
        param(channel.comp, "threshold")?.value = AUValue(-45 * a)
        param(channel.comp, "attack")?.value = 5
        param(channel.comp, "release")?.value = 250
        param(channel.comp, "headroom")?.value = 8
        param(channel.comp, "masterGain")?.value = AUValue(3 * a)
        setBypass(channel.comp, !fx.compOn || a <= 0)
        param(channel.reverb, "wetDry")?.value = AUValue(min(1, max(0, fx.reverbMix)) * 100)
        param(channel.reverb, "decay")?.value = 1.8
        setBypass(channel.reverb, !fx.reverbOn)
    }

    /// FILTER knob: 20 Hz…18 kHz. `enabled` is the Nord-style on/off.
    public func setFilter(enabled: Bool, cutoffHz: Double) {
        param(filterUnit, "cutoff")?.value = AUValue(min(18_000, max(20, cutoffHz)))
        setBypass(filterUnit, !enabled)
    }

    /// COMPRESSOR amount 0…1: maps to threshold (0→−45 dB) with gentle makeup gain.
    public func setCompressor(amount: Double) {
        let a = min(1, max(0, amount))
        param(compUnit, "threshold")?.value = AUValue(-45 * a)
        param(compUnit, "attack")?.value = 5 // ms
        param(compUnit, "release")?.value = 250 // ms
        param(compUnit, "headroom")?.value = 8 // dB of soft knee
        param(compUnit, "masterGain")?.value = AUValue(3 * a) // dB makeup
        setBypass(compUnit, a <= 0)
    }

    /// REVERB: wet/dry mix 0…1 and room size mapped to decay time.
    public func setReverb(mix: Double, decaySeconds: Double) {
        let m = min(1, max(0, mix))
        param(reverbUnit, "wetDry")?.value = AUValue(m * 100)
        param(reverbUnit, "decay")?.value = AUValue(min(20, max(0.1, decaySeconds)))
        setBypass(reverbUnit, m <= 0)
    }

    // MARK: - MIDI

    private var midiClient: MIDIClientRef?
    private var midiPort: MIDIPortRef?
    private var connectedMidiSources: Set<MIDIEndpointRef> = []

    private func setupMIDI() throws {
        var client = MIDIClientRef()
        guard MIDIClientCreateWithBlock("nordpiano" as CFString, &client, { _ in }) == noErr else {
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
            if MIDIPortConnectSource(port, s, nil) == noErr { connectedMidiSources.insert(s) }
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
        for layer in snapshot {
            guard let key = pianoKey(layer.piano.zones, midi: note),
                  let stroke = strokeFor(layer.piano.dir, zone: key.zone, velocity: velocity) else { continue }
            let picked = (stroke: cachedOrDecodePiano(layer, stroke),
                          rootKey: layer.piano.zones[key.zone].rootNote + Nsp.rootOffset)

            let gain = Float(pow(10, -touchAttenuation(velocity) / 100)) * mixHeadroom * layer.gain
            var v = Voice(pcm: picked.stroke.pcm, rate: 1, gain: gain, note: note)
            let semitones = Double(note - picked.rootKey)
            v.rate = pow(2, semitones / 12) * (picked.stroke.sampleRate / outRate)
            if let loopStart = picked.stroke.loopStart {
                v.hasLoop = true
                v.loopStart = Double(loopStart)
                v.loopEnd = Double(picked.stroke.pcm[0].count)
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

    private func cachedOrDecodePiano(_ layer: Layer, _ stroke: NspStroke) -> CachedStroke {
        lock.lock(); let cached = layer.cache[stroke.index]; lock.unlock()
        if let cached { return cached }
        let decoded = (try? decodeNspStroke(layer.piano.bytes, dir: layer.piano.dir, stroke: stroke)) ?? []
        let pcm = decoded.map { ch in ch.map { Float($0) / 32768 } }
        let result = CachedStroke(pcm: pcm, sampleRate: Double(Nsp.sampleRate),
                                  loopStart: stroke.loop.map { $0.start },
                                  decayDbPerSecond: 0)
        lock.lock()
        if let idx = layers.firstIndex(where: { $0.id == layer.id }) {
            layers[idx].cache[stroke.index] = result
        }
        lock.unlock()
        return result
    }

    // MARK: - Render (audio thread, one source-node callback per channel)

    private func render(channelID: URL, intoL outL: UnsafeMutablePointer<Float>, r outR: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock()
        guard let channel = channels[channelID] else { lock.unlock(); return }
        var active = channel.voices
        channel.voices.removeAll(keepingCapacity: true)
        lock.unlock()

        let (keep, notes) = renderVoices(&active, intoL: outL, r: outR, frames: frames)

        lock.lock()
        if let channel = channels[channelID] {
            channel.voices.append(contentsOf: keep)
        }
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

    /// Mix one block of voices into the output. Returns the surviving voices and their notes.
    private func renderVoices(_ active: inout [Voice], intoL outL: UnsafeMutablePointer<Float>, r outR: UnsafeMutablePointer<Float>, frames: Int) -> (keep: [Voice], notes: Set<Int>) {
        let releaseStep = Float(exp(-1 / (releaseTau * outRate)))
        var keep: [Voice] = []
        keep.reserveCapacity(active.count)

        for frame in 0..<frames {
            outL[frame] = 0
            outR[frame] = 0
        }

        for vi in active.indices {
            var v = active[vi]
            let count = v.pcm[0].count
            let stereo = v.pcm.count == 2
            var frame = 0
            var alive = true

            while frame < frames {
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
                let l = (v.pcm[0][p0] + (v.pcm[0][p1] - v.pcm[0][p0]) * frac) * v.env * v.gain
                let r = stereo
                    ? (v.pcm[1][p0] + (v.pcm[1][p1] - v.pcm[1][p0]) * frac) * v.env * v.gain
                    : l
                outL[frame] += l
                outR[frame] += r
                v.pos += v.rate
                if v.hasLoop && v.pos >= v.loopStart && v.pos < v.loopEnd {
                    v.gain *= v.loopDecayPerFrame
                }
                frame += 1
            }
            if alive { keep.append(v) }
        }
        return (keep, Set(keep.map(\.note)))
    }
}

public extension PianoPlayer {
    var soundingNotesHandler: (@Sendable (Set<Int>) -> Void)? {
        get { onSoundingNotes }
        set { onSoundingNotes = newValue }
    }
}
