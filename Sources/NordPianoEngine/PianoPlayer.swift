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
    // Exactly one of these is set:
    var piano: (bytes: [UInt8], dir: NspDirectory, zones: [NspZone])?
    var sample: (handle: Int, zones: [NsmpBridge.Zone])?
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
    private var voices: [Voice] = []
    private var sustainPedal = false
    private var outRate: Double = 44_100

    private var filterUnit: AVAudioUnit?
    private var compUnit: AVAudioUnit?
    private var reverbUnit: AVAudioUnit?

    var onSoundingNotes: (@Sendable (Set<Int>) -> Void)?
    private var lastSounding: Set<Int> = []

    private let releaseTau = 0.05 // key-up fade, ~60 dB in a third of a second
    private let mixHeadroom: Float = 0.35
    private let maxVoices = 128

    /// Single-piano convenience init (CLI).
    public convenience init(bytes: [UInt8]) throws {
        self.init()
        _ = try addLayer(bytes: bytes, id: URL(fileURLWithPath: "piano.npno"))
    }

    /// Add a Nord Sample (.nsmp/.nsmp3/.nsmp4) to the layered mix.
    @discardableResult
    public func addSampleLayer(bytes: [UInt8], id: URL, gain: Float = 1) throws -> Int {
        let file = try NsmpBridge.shared.load(bytes: bytes)
        guard !file.zones.isEmpty else { throw NspError.noDirectory }
        lock.lock()
        layers.append(Layer(id: id, gain: gain, sample: (handle: file.handle, zones: file.zones)))
        let idx = layers.count - 1
        lock.unlock()
        return idx
    }

    public init() {}

    // MARK: - Layers

    /// Add a piano to the layered mix; returns its index. Layers mix in parallel.
    @discardableResult
    public func addLayer(bytes: [UInt8], id: URL, gain: Float = 1) throws -> Int {
        let dir = try readNspDirectory(bytes)
        let zones = readNspZones(bytes)
        guard !zones.isEmpty else { throw NspError.noDirectory }
        lock.lock()
        layers.append(Layer(id: id, gain: gain, piano: (bytes: bytes, dir: dir, zones: zones)))
        let idx = layers.count - 1
        lock.unlock()
        return idx
    }

    /// MIDI notes of recorded samples across layers (keyboard markers).
    public var markers: [Int] {
        lock.lock(); defer { lock.unlock() }
        return layers.flatMap { layer -> [Int] in
            if let p = layer.piano { return p.zones.map { $0.rootNote + Nsp.rootOffset } }
            if let s = layer.sample { return s.zones.map { $0.rootKey } }
            return []
        }
    }

    public func removeLayer(id: URL) {
        lock.lock()
        layers.removeAll { $0.id == id }
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

        let source = AVAudioSourceNode(format: format) { [weak self] isSilence, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(intoL: outL, r: outR, frames: Int(frameCount))
            isSilence.pointee = false
            return noErr
        }
        engine.attach(source)

        // FX insert units, created synchronously (they're on-disk Apple units — fast).
        func makeEffect(_ subtype: OSType) throws -> AVAudioUnit {
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
        filterUnit = try makeEffect(kAudioUnitSubType_LowPassFilter)
        compUnit = try makeEffect(kAudioUnitSubType_DynamicsProcessor)
        reverbUnit = try makeEffect(kAudioUnitSubType_Reverb2)
        for unit in [filterUnit, compUnit, reverbUnit] { engine.attach(unit!) }

        engine.connect(source, to: filterUnit!, format: format)
        engine.connect(filterUnit!, to: compUnit!, format: format)
        engine.connect(compUnit!, to: reverbUnit!, format: format)
        engine.connect(reverbUnit!, to: engine.mainMixerNode, format: format)
        try engine.start()

        // Defaults: everything neutral/bypassed.
        setFilter(enabled: false, cutoffHz: 18_000)
        setCompressor(amount: 0)
        setReverb(mix: 0, decaySeconds: 1.8)

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
        let sources = MIDIGetNumberOfSources()
        for i in 0..<sources {
            MIDIPortConnectSource(port, MIDIGetSource(i), nil)
        }
        if sources == 0 { print("nordpiano: warning — no MIDI sources found") }
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
            let picked: (stroke: CachedStroke, rootKey: Int)?
            if let piano = layer.piano {
                guard let key = pianoKey(piano.zones, midi: note),
                      let stroke = strokeFor(piano.dir, zone: key.zone, velocity: velocity) else { continue }
                picked = (stroke: cachedOrDecodePiano(layer, stroke), rootKey: piano.zones[key.zone].rootNote + Nsp.rootOffset)
            } else if let sample = layer.sample {
                guard let zone = Self.pickZone(sample.zones, note: note, velocity: velocity) else { continue }
                guard let stroke = cachedOrDecodeSample(layer, globalID: zone.globalID) else { continue }
                picked = (stroke: stroke, rootKey: zone.rootKey)
            } else { continue }
            guard let picked else { continue }

            let gain = Float(pow(10, -touchAttenuation(velocity) / 100)) * mixHeadroom * layer.gain
            lock.lock()
            if voices.count >= maxVoices, let idx = voices.firstIndex(where: { !$0.sustained && !$0.releasing }) {
                voices[idx].releasing = true
                voices[idx].env = 0 // stolen
            }
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
            voices.append(v)
            lock.unlock()
        }
    }

    public func noteOff(_ note: Int) {
        lock.lock()
        for i in voices.indices where voices[i].note == note && !voices[i].releasing {
            if sustainPedal { voices[i].sustained = true } else { voices[i].releasing = true }
        }
        lock.unlock()
    }

    public func sustain(_ down: Bool) {
        lock.lock()
        sustainPedal = down
        if !down {
            for i in voices.indices where voices[i].sustained {
                voices[i].sustained = false
                voices[i].releasing = true
            }
        }
        lock.unlock()
    }

    /// Sample zone pick: keys in range, then the velocity band; nearest key range otherwise.
    static func pickZone(_ zones: [NsmpBridge.Zone], note: Int, velocity: Int) -> NsmpBridge.Zone? {
        let inKey = zones.filter { $0.keyLow <= note && note <= $0.keyHigh }
        let band = inKey.first(where: { $0.velLow <= velocity && velocity <= $0.velTop })
        if let band { return band }
        if let any = inKey.max(by: { $0.velTop < $1.velTop }) { return any }
        return zones.filter({ $0.keyHigh >= note }).min(by: { $0.keyHigh < $1.keyHigh })
    }

    private func cachedOrDecodePiano(_ layer: Layer, _ stroke: NspStroke) -> CachedStroke {
        lock.lock(); let cached = layer.cache[stroke.index]; lock.unlock()
        if let cached { return cached }
        let decoded = (try? decodeNspStroke(layer.piano!.bytes, dir: layer.piano!.dir, stroke: stroke)) ?? []
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

    private func cachedOrDecodeSample(_ layer: Layer, globalID: Int) -> CachedStroke? {
        lock.lock(); let cached = layer.cache[globalID]; lock.unlock()
        if let cached { return cached }
        guard let s = try? NsmpBridge.shared.decodeStroke(handle: layer.sample!.handle, globalID: globalID) else { return nil }
        // Sample codecs have varying int scales (16/24-bit) — normalize to full scale.
        var pcm = s.channels
        if let peak = pcm.flatMap({ $0.map(abs) }).max(), peak > 0 {
            let scale = 0.95 / peak
            pcm = pcm.map { $0.map { $0 * scale } }
        }
        let result = CachedStroke(pcm: pcm, sampleRate: s.sampleRate,
                                  loopStart: s.loopStart, decayDbPerSecond: s.decayDbPerSecond)
        lock.lock()
        if let idx = layers.firstIndex(where: { $0.id == layer.id }) {
            layers[idx].cache[globalID] = result
        }
        lock.unlock()
        return result
    }

    // MARK: - Render (audio thread)

    private func render(intoL outL: UnsafeMutablePointer<Float>, r outR: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock()
        var active = voices
        voices.removeAll(keepingCapacity: true)
        lock.unlock()

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

        lock.lock()
        voices.append(contentsOf: keep)
        lock.unlock()

        let notes = Set(keep.map(\.note))
        if notes != lastSounding {
            lastSounding = notes
            let handler = onSoundingNotes
            DispatchQueue.main.async { handler?(notes) }
        }
    }
}

public extension PianoPlayer {
    var soundingNotesHandler: (@Sendable (Set<Int>) -> Void)? {
        get { onSoundingNotes }
        set { onSoundingNotes = newValue }
    }
}
