import Foundation
import SwiftUI
import CoreAudio
import CoreMIDI
import NordPianoCore
import NordPianoEngine

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

@MainActor
final class PlayerModel: ObservableObject {
    struct PianoEntry: Identifiable, Hashable {
        var id: URL { url } // URL-keyed: selection, gains and favorites survive rescans
        let url: URL
        let name: String
        let version: String
        let folder: String // containing folder, relative to its root (for grouping)
        var kind: String { "PIANO" }
    }

    @Published var pianoTitle = "No piano loaded"
    @Published var version = ""
    @Published var velocity: Double = 80
    @Published var masterVolume: Double = 1 { didSet { player?.setMasterVolume(Float(masterVolume)) } }
    @Published var boostDb: Double = 0 { didSet { player?.setMasterBoost(dB: Float(boostDb)) } }
    @Published var sounding: Set<Int> = []
    /// Last parsed MIDI message ("Note On C4 (60) vel 87 ch 1") — footer readout.
    @Published var midiActivity = ""
    @Published var status = "Drop a .npno or .nsmp4 file anywhere, or Open…"
    @Published var roots: [URL] = []
    @Published var library: [PianoEntry] = []

    /// One mixer channel: a stable slot ID (the engine's layer ID) holding a
    /// sound. Ordered — mixer strips and scenes follow this order.
    struct ChannelState: Identifiable, Hashable {
        let id: UUID
        var entry: PianoEntry
    }
    /// The layered channels, in order. Replaces the old `selected` set.
    @Published var channels: [ChannelState] = []
    /// The channel the "→" assign button targets (tap a mixer strip to pick it).
    @Published var selectedChannelID: UUID?
    /// Sidebar highlight: the sound the "→" button would assign.
    @Published var highlighted: PianoEntry?

    /// Sounds currently loaded, as a set (row highlighting, gains slider).
    var selected: Set<PianoEntry> { Set(channels.map(\.entry)) }
    @Published var gains: [URL: Float] = [:]
    /// Muted layers (mixer mute buttons).
    @Published var muted: Set<URL> = []
    /// Per-layer mixer settings (EQ/filter/comp/reverb), keyed by layer URL, persisted.
    @Published var layerFX: [URL: PianoPlayer.LayerFX] = [:] {
        didSet { persistLayerFX() }
    }
    @Published var favorites: [PianoEntry] = []
    /// Show the on-screen keyboard; hidden removes the view entirely (no rendering at all).
    @Published var showKeyboard: Bool = UserDefaults.standard.object(forKey: "showKeyboard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showKeyboard, forKey: "showKeyboard") }
    }

    // FX
    @Published var filterOn = false { didSet { applyFX() } }
    @Published var filterNorm: Double = 1 { didSet { applyFX() } }
    @Published var compOn = false { didSet { applyFX() } }
    @Published var compAmount: Double = 0.3 { didSet { applyFX() } }
    @Published var delayOn = false { didSet { applyFX() } }
    @Published var delayTime: Double = 0.25 { didSet { applyFX() } }
    @Published var delayFeedback: Double = 0.3 { didSet { applyFX() } }
    @Published var delayMix: Double = 0.2 { didSet { applyFX() } }
    @Published var reverbOn = false { didSet { applyFX() } }
    @Published var reverbMix: Double = 0.2 { didSet { applyFX() } }
    @Published var reverbSize: Double = 0.4 { didSet { applyFX() } }

    private(set) var player: PianoPlayer?
    @Published var markers: [Int] = []
    /// Keys pressed on screen (so the keyboard shows UI touches even before voices sound).
    @Published var uiHeld: Set<Int> = []

    // MARK: - Catalog (imported, categorized sounds)

    /// The app-managed library of imported sounds, persisted as JSON.
    @Published var catalog = SoundCatalog.load()

    /// Import files into the catalog (copy into the managed library, classify by
    /// name heuristics). `overrides` comes from the import review sheet: a picked
    /// category/subcategory per URL beats the heuristic. Misclassified entries
    /// can be moved afterwards.
    func importSounds(_ urls: [URL],
                      overrides: [URL: (category: SoundCategory, subcategory: String?)] = [:]) {
        var ok = 0
        for url in urls {
            do {
                let override = overrides[url]
                _ = try catalog.importFile(at: url, category: override?.category,
                                           subcategory: override?.subcategory)
                ok += 1
            } catch {
                status = "Import error: \(error.localizedDescription)"
            }
        }
        try? catalog.save()
        if ok > 0 { status = "Imported \(ok) sound\(ok == 1 ? "" : "s") into the library" }
    }

    /// Sound bank bundles import as collections, not as playable files.
    func isBundle(_ url: URL) -> Bool {
        ["nw2pbundle", "ne6pbundle", "ns4pbundle"].contains(url.pathExtension.lowercased())
    }

    /// Import a signature sound bank (`.nw2pbundle` / `.ne6pbundle` /
    /// `.ns4pbundle`): every referenced sound is copied into the catalog, and
    /// each decoded program becomes a scene in a collection named after the
    /// bundle. Sounds are matched to engine slots by their MurmurHash2 name
    /// hash (the NW2's numeric sample ids are the fallback). Synth-oscillator
    /// and organ slots are skipped — we have no engine to reproduce them.
    func importBundle(url: URL) {
        do {
            let bundle = try extractNw2pBundle(url)
            defer { try? FileManager.default.removeItem(at: bundle.directory) }
            // Import each referenced sound once (several programs share them).
            var entriesBySample: [String: CatalogEntry] = [:]
            for program in bundle.programs {
                for sample in program.samples where entriesBySample[sample] == nil {
                    let file = bundle.directory.appendingPathComponent(sample)
                    entriesBySample[sample] = try catalog.importFile(at: file)
                }
            }
            try? catalog.save()
            // Hash → dep file: the program names its sounds by MurmurHash2 of
            // the library name (file name minus extension).
            var depByHash: [UInt32: String] = [:]
            for sample in Set(bundle.programs.flatMap(\.samples)) {
                depByHash[soundId(soundLibraryName(ofFile: (sample as NSString).lastPathComponent))] = sample
            }

            let format = url.pathExtension.lowercased() // see isBundle
            // Decode every program binary (nil = layout mismatch).
            let decoded: [String: FwProgram] = Dictionary(uniqueKeysWithValues:
                bundle.programs.compactMap { program in
                    guard let bytes = try? [UInt8](Data(contentsOf: bundle.directory.appendingPathComponent(program.file))) else { return nil }
                    let p: FwProgram = switch format {
                    case "ne6pbundle": FwDecoder.decodeNe6(bytes)
                    case "ns4pbundle": FwDecoder.decodeNs4(bytes)
                    default: FwDecoder.decodeNw2(bytes)
                    }
                    return p.layoutMatched ? (program.name, p) : nil
                })
            // NW2 fallback: resolve numeric sample ids when no hash matches.
            let waveToSample: [Int: String] = format == "nw2pbundle"
                ? resolveNw2SampleIDs(programs: bundle.programs,
                                      sampleSlots: Dictionary(uniqueKeysWithValues:
                                        bundle.programs.map { program in
                                            let p = decoded[program.name]
                                            return (program.name, FwProgram.nw2Slots.compactMap { slot in
                                                guard let p, p.nw2SlotEnabled(slot) == true,
                                                      let src = p.nw2SlotSource(slot), src.isSample else { return nil }
                                                return (slot, src.wave)
                                            })
                                        }))
                : [:]

            let collection = collectionName(for: url)
            var made = 0, skippedLayers = 0, droppedPrograms = 0
            for program in bundle.programs {
                guard let p = decoded[program.name] else { droppedPrograms += 1; continue }
                var sounds: [String] = []
                var soundIDs: [UUID?] = []
                var gains: [String: Float] = [:]
                var layerFX: [String: PianoPlayer.LayerFX] = [:]
                /// Append one engine slot: dep path by hash (or NW2 wave id),
                /// gain from the level field, FX from the per-slot blocks.
                func addSlot(hash: Int?, wave: Int?, level: Int?, ns4Taper: Bool = false,
                             slotFX: PianoPlayer.LayerFX) {
                    let dep = hash.flatMap { $0 == emptySoundHash ? nil : depByHash[UInt32($0)] }
                        ?? wave.flatMap { waveToSample[$0] }
                    guard let dep, let entry = entriesBySample[dep] else {
                        skippedLayers += 1
                        return
                    }
                    sounds.append(entry.path)
                    soundIDs.append(entry.id)
                    if let level {
                        gains[entry.path] = Float(ns4Taper ? Self.ns4LevelGain(Double(level)) : Double(level) / 127)
                    }
                    layerFX[entry.path] = slotFX
                }
                switch format {
                case "ne6pbundle":
                    if p.value("piano.enable") == 1 {
                        addSlot(hash: p.value("piano.nameHash"), wave: nil,
                                level: p.value("piano.level"), slotFX: ne6LayerFX(p, engine: "piano"))
                    }
                    if p.value("synth.enable") == 1 {
                        addSlot(hash: p.value("synth.smpNameHash"), wave: nil,
                                level: p.value("synth.level"), slotFX: ne6LayerFX(p, engine: "synth"))
                    }
                    if p.value("organ.enable") == 1 { skippedLayers += 1 }
                case "ns4pbundle":
                    for slot in ["A", "B"] {
                        // Piano layer on when it references a dep and isn't muted.
                        if let hash = p.value("piano\(slot).nameHash"), hash != 0,
                           (p.value("piano.layerLevelPno\(slot)") ?? 0) > 0 {
                            var slotFX = PianoPlayer.LayerFX()
                            guard let range = ns4KeyRange(p, layer: "piano\(slot)") else {
                                skippedLayers += 1
                                continue
                            }
                            slotFX.keyLow = range.lowerBound
                            slotFX.keyHigh = range.upperBound
                            if let oct = p.value("piano\(slot).octaveShift") { slotFX.octaveShift = oct * 12 } // stored in octaves
                            applyLevelMorphs(p, key: "piano.layerLevelPno\(slot)", pedal: "morphCtrlPedal",
                                             gain: Self.ns4LevelGain, to: &slotFX)
                            addSlot(hash: hash, wave: nil,
                                    level: p.value("piano.layerLevelPno\(slot)"), ns4Taper: true,
                                    slotFX: applyNs4FxBlock(p, block: "piano\(slot)Fx", to: slotFX))
                        }
                    }
                    for slot in ["A", "B", "C"] {
                        // mode 0 = samples, 1 = analog oscillator (not playable here).
                        if let hash = p.value("synth\(slot).smpNameHash"), hash != 0,
                           hash != emptySoundHash,
                           (p.value("synth.layerLevelSyn\(slot)") ?? 0) > 0 {
                            guard p.value("synth\(slot).mode") ?? 0 == 0,
                                  ns4KeyRange(p, layer: "synth\(slot)") != nil else {
                                skippedLayers += 1
                                continue
                            }
                            addSlot(hash: hash, wave: nil,
                                    level: p.value("synth.layerLevelSyn\(slot)"), ns4Taper: true,
                                    slotFX: ns4LayerFX(p, slot: slot))
                        }
                    }
                    if (p.value("organ.layerLevelOrgA") ?? 0) > 0 || (p.value("organ.layerLevelOrgB") ?? 0) > 0 {
                        skippedLayers += 1
                    }
                default: // nw2pbundle
                    for slot in FwProgram.nw2Slots {
                        guard p.nw2SlotEnabled(slot) == true, let src = p.nw2SlotSource(slot) else { continue }
                        guard src.isSample else { skippedLayers += 1; continue }
                        addSlot(hash: p.value("slot\(slot)Common.smpNameHash"), wave: src.wave,
                                level: p.value("common.slotLevel\(slot)"),
                                slotFX: nw2LayerFX(p, slot: slot))
                    }
                }
                guard !sounds.isEmpty else { droppedPrograms += 1; continue }
                scenes.append(Scene(name: program.name, collection: collection,
                                    sounds: sounds, soundIDs: soundIDs,
                                    gains: gains, layerFX: layerFX))
                made += 1
            }
            status = "Imported \(entriesBySample.count) sounds, \(made) scenes to “\(collection)”"
                + (skippedLayers > 0 ? " — \(skippedLayers) synth/organ layers skipped" : "")
                + (droppedPrograms > 0 ? ", \(droppedPrograms) programs without playable layers" : "")
        } catch {
            status = "Bundle import error: \(error.localizedDescription)"
        }
    }

    /// "Elijah Fox Signature Sound Bank Bundle.nw2pbundle" → "Elijah Fox Signature Sound Bank".
    private func collectionName(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        for suffix in [" Bundle", "_Bundle"] {
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        }
        return name.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Collections in import order: (name, its scenes). User scenes
    /// (collection == nil) live in the regular scenes list instead.
    var collections: [(name: String, scenes: [Scene])] {
        var order: [String] = []
        var byName: [String: [Scene]] = [:]
        for scene in scenes {
            guard let name = scene.collection else { continue }
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(scene)
        }
        return order.map { ($0, byName[$0]!) }
    }

    /// Scenes not belonging to any bundle — the scenes column / perform page.
    var userScenes: [Scene] { scenes.filter { $0.collection == nil } }

    /// Remove a whole collection (its scenes; the sounds stay in the library).
    func deleteCollection(_ name: String) {
        scenes.removeAll { $0.collection == name }
    }

    /// Nord amp attack code (0…127) → our ATTACK knob (cubic, 0…10 s).
    private func envAttackNorm(_ v127: Double) -> Double {
        let seconds = SynthCurves.attackSeconds(v127 / 127)
        return seconds < 0.002 ? 0 : min(1, pow(seconds / 10, 1.0 / 3.0))
    }

    /// Nord amp release code (0…127, time to silence) → our RELEASE knob,
    /// whose value is an exponential time constant 50 ms…3 s (≈ time / 6.9).
    private func envReleaseNorm(_ v127: Double) -> Double {
        let tau = SynthCurves.decaySeconds(v127 / 127) / 6.9
        return min(1, max(0, log(max(0.05, tau) / 0.05) / log(60)))
    }

    /// NS4 layer volume code → linear gain. The Stage 4 volume knob is a dB
    /// taper (127 = 0 dB, 96 = −4.9, 64 = −11.9, 32 = −23.9, 0 = off), not linear.
    static func ns4LevelGain(_ code: Double) -> Double {
        let anchors: [(Double, Double)] = [(0, -80), (32, -23.9), (64, -11.9), (96, -4.9), (127, 0)]
        let x = min(127, max(0, code))
        guard x > 0 else { return 0 }
        for i in 1..<anchors.count where x <= anchors[i].0 {
            let (x0, y0) = anchors[i - 1], (x1, y1) = anchors[i]
            return pow(10, (y0 + (y1 - y0) * (x - x0) / (x1 - x0)) / 20)
        }
        return 1
    }

    /// A stored morph delta: `delta + (max − min)` for the base field's range;
    /// normalized to −1…1 (clamped).
    private func morphDelta(_ stored: Int?, range: Double = 127) -> Double {
        guard let stored else { return 0 }
        return max(-1, min(1, (Double(stored) - range) / range))
    }

    /// Level morphs are stored as deltas on the 0…127 level; the engine wants
    /// them relative to the layer's own gain. `gain` maps a level code to the
    /// engine gain (linear for NW2, the dB taper for NS4).
    private func relativeLevelMorph(_ stored: Int?, level: Int?,
                                    gain: (Double) -> Double) -> Double {
        let delta = morphDelta(stored)
        guard delta != 0, let level, level > 0 else { return 0 }
        let base = gain(Double(level))
        guard base > 0 else { return 0 }
        let target = gain(min(127, max(0, Double(level) + delta * 127)))
        return max(-1, min(8, target / base - 1))
    }

    /// Wheel/aftertouch/pedal level morphs for one layer whose level field is
    /// `key` (pedal suffix differs: NW2 `morphPedal`, NS4 `morphCtrlPedal`).
    private func applyLevelMorphs(_ p: FwProgram, key: String, pedal: String,
                                  gain: @escaping (Double) -> Double = { $0 / 127 },
                                  to fx: inout PianoPlayer.LayerFX) {
        let level = p.value(key)
        fx.wheelToLevel = relativeLevelMorph(p.value("\(key).morphWheel"), level: level, gain: gain)
        fx.atToLevel = relativeLevelMorph(p.value("\(key).morphAfterTouch"), level: level, gain: gain)
        fx.pedalToLevel = relativeLevelMorph(p.value("\(key).\(pedal)"), level: level, gain: gain)
    }

    /// NS4 keyboard zone for an engine layer (`synthA`, `pianoB`, …) from its
    /// kbZone and the program's split points. nil = the layer plays nowhere.
    private func ns4KeyRange(_ p: FwProgram, layer: String) -> ClosedRange<Int>? {
        let points = ["Low", "Mid", "High"].map { side in
            (enabled: p.value("common.splitEnabled\(side)") == 1,
             position: p.value("common.splitPos\(side)") ?? 0)
        }
        return Ns4Zones.keyRange(kbZone: p.value("\(layer).kbZone") ?? 0,
                                 split: p.value("common.splitEnabled") == 1, points: points)
    }

    /// NS4 pitch-stick range table (pitchStickRange 0…9) → (up, down) semitones.
    private static let ns4BendRanges = [(1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (7, 7),
                                        (10, 10), (12, 12), (2, 12), (2, 24)]

    /// Map a decoded NS4 synth layer onto our channel FX: keyboard zone, voice
    /// mode + priority + glide, pitch stick, sustain switch, pan, then the Sound
    /// block (filter + envelope, amp envelope, LFO, vibrato, unison→chorus) and
    /// the shared FX block (amp EQ + drive, compressor, delay, reverb).
    private func ns4LayerFX(_ p: FwProgram, slot: String) -> PianoPlayer.LayerFX {
        var fx = PianoPlayer.LayerFX()
        func v(_ key: String) -> Double? { p.value("synth\(slot)Sound.\(key)").map(Double.init) }
        func layer(_ key: String) -> Int? { p.value("synth\(slot).\(key)") }
        if let range = ns4KeyRange(p, layer: "synth\(slot)") {
            fx.keyLow = range.lowerBound
            fx.keyHigh = range.upperBound
        }
        // Voice mode 0=Poly 1=Mono 2=Legato; priority 0=last 1=low 2=high.
        if let mode = layer("voiceMode"), mode >= 1 {
            fx.monoOn = true
            fx.legato = mode == 2
            fx.voicePriority = layer("voicePrio") ?? 0
            fx.glideNorm = Double(layer("glideRate") ?? 0) / 127
        }
        if layer("pStickEnable") == 0 {
            fx.bendUp = 0
            fx.bendDown = 0
        } else if let range = layer("pitchStickRange"), Self.ns4BendRanges.indices.contains(range) {
            (fx.bendUp, fx.bendDown) = Self.ns4BendRanges[range]
        }
        fx.ignoresSustain = layer("sustainEnable") == 0
        if let pan = p.value("synth.layerPanSyn\(slot)") { fx.pan = Double(pan) / 60 }
        if let oct = layer("octaveShift") { fx.octaveShift = oct * 12 } // octaves → semitones
        if v("fltEnable") == 1 {
            fx.filterOn = true
            fx.filterType = Int(v("fltType") ?? 0)
            fx.filterNorm = (v("fltFreq") ?? 127) / 127
            if fx.filterType == SynthFilterType.lpHp.rawValue {
                // LP+HP: the resonance knob sets the high-pass corner instead.
                fx.filterHPNorm = (v("fltRes") ?? 0) / 127
            } else {
                fx.filterRes = (v("fltRes") ?? 0) / 127
            }
            fx.filterKeyTrack = (v("fltKbdTrk") ?? 0) / 3
            fx.fltEnvAmt = (v("fltEnvAmt") ?? 0) / 127
            fx.fltEnvAtk = (v("fltEnvAtk") ?? 0) / 127
            // NS4 envelopes are A-D-R: decay falls to zero unless it's at max
            // (127 = ∞, i.e. sustain at peak).
            let dcy = v("fltEnvDcy") ?? 0
            fx.fltEnvDcy = dcy / 127
            fx.fltEnvSus = dcy >= 127 ? 1 : 0
            fx.fltEnvRls = (v("fltEnvRls") ?? 0) / 127
            fx.fltEnvVel = v("fltEnvVel") ?? 0
        }
        // Morphs (stored as delta + range): wheel/aftertouch/pedal → cutoff and level.
        fx.wheelToCutoff = morphDelta(p.value("synth\(slot)Sound.fltFreq.morphWheel"))
        fx.atToCutoff = morphDelta(p.value("synth\(slot)Sound.fltFreq.morphAfterTouch"))
        fx.pedalToCutoff = morphDelta(p.value("synth\(slot)Sound.fltFreq.morphCtrlPedal"))
        applyLevelMorphs(p, key: "synth.layerLevelSyn\(slot)", pedal: "morphCtrlPedal",
                         gain: Self.ns4LevelGain, to: &fx)
        if let drive = v("fltDrive"), drive > 0 {
            fx.driveOn = true
            fx.driveNorm = drive / 3
        }
        // Amp envelope: A-D-R, decay at max = sustain.
        if let atk = v("ampEnvAtk") { fx.attackNorm = envAttackNorm(atk) }
        if let dcy = v("ampEnvDcy"), dcy < 127 {
            fx.ampDecay = dcy / 127
            fx.ampSustain = 0
        }
        if let rls = v("ampEnvRls") { fx.releaseTimeNorm = envReleaseNorm(rls) }
        // Amp velocity sensitivity 0…3 → extra touch response.
        if let vel = v("ampEnvVel"), vel > 0 { fx.velToLevel = max(fx.velToLevel, vel / 3 * 0.5) }
        // LFO: destination 0=none 1=osc ctrl (no oscillator here) 2=pitch 3=filter.
        if let amt = v("lfoAmt"), amt > 0, let dst = v("lfoDst"), dst >= 2 {
            fx.lfoDepth = amt / 127
            fx.lfoDest = dst == 2 ? SynthLfoDest.pitch.rawValue : SynthLfoDest.filter.rawValue
            fx.lfoShape = Int(v("lfoWave") ?? 0)
            fx.lfoRate = (v("lfoRateClkDiv") ?? 64) / 127
        }
        // Vibrato: pitch, with its own source (off/on/delay/wheel/AT/pedal).
        fx.vibMode = layer("vibMode") ?? 0
        fx.vibDepth = (v("vibAmt") ?? 0) / 50
        fx.vibRate = (v("vibRate") ?? 64) / 127
        fx.vibDelay = Double(layer("vibDly") ?? 0) * 0.1
        // Unison (detuned stacked voices) approximated by our chorus ensemble.
        if let unison = layer("oscUnison"), unison > 0 {
            fx.chorusOn = true
            fx.chorusDepth = 0.25 + Double(unison) / 3 * 0.5
            fx.chorusRate = 0.3
        }
        // Arpeggiator: run, mode (Arp/Poly/Gate), direction, range (the 0…127
        // knob spans 1…4 octaves), free rate; KB hold latches the pattern.
        if layer("arpRun") == 1 {
            fx.arpOn = true
            fx.arpMode = layer("arpMode") ?? 0
            fx.arpDirection = layer("arpDir") ?? 0
            fx.arpOctaves = 1 + Int((Double(layer("arpRange") ?? 0) / 127 * 3).rounded())
            fx.arpRate = Double(layer("arpRateClkDiv") ?? 78) / 127
            fx.arpHold = layer("kbdHoldEnableLayer") == 1 && p.value("synth.kbdHoldEnableCommon") == 1
        }
        return applyNs4FxBlock(p, block: "synth\(slot)Fx", to: fx)
    }

    /// The FX block shared by every NS4 engine (amp EQ + drive, compressor,
    /// delay, reverb) — same field layout under pianoAFx/pianoBFx/synthXFx.
    private func applyNs4FxBlock(_ p: FwProgram, block: String,
                                 to fx: PianoPlayer.LayerFX) -> PianoPlayer.LayerFX {
        var fx = fx
        func v(_ key: String) -> Double? { p.value("\(block).\(key)").map(Double.init) }
        if v("ampEnable") == 1 {
            fx.eqLow = (v("ampBass") ?? 0) / 60
            fx.eqMid = (v("ampMid") ?? 0) / 60
            fx.eqHigh = (v("ampTreble") ?? 0) / 60
            if let drive = v("ampDrive"), drive > 0 {
                fx.driveOn = true
                fx.driveNorm = max(fx.driveNorm, drive / 127)
            }
        }
        if v("cmpEnable") == 1 {
            fx.compOn = true
            fx.compAmount = (v("cmpAmt") ?? 0) / 127
        }
        if v("dlyEnable") == 1 {
            fx.delayOn = true
            fx.delayMix = (v("dlyMix") ?? 0) / 127
            fx.delayFeedback = (v("dlyFbkAmt") ?? 0) / 127
            fx.delayTime = min(2, (v("dlyRateClkDiv") ?? 0) / 16383 * 2)
        }
        if v("rvbEnable") == 1 {
            fx.reverbOn = true
            fx.reverbMix = (v("rvbAmt") ?? 0) / 127
            fx.reverbSize = (v("rvbType") ?? 0) / 11
        }
        return fx
    }

    /// Map a decoded NE6 program's sample-synth layer onto our channel FX:
    /// filter (no enable flag — "on" when it actually cuts; type + key
    /// tracking), amp envelope, and the shared effects unit when its source
    /// selector points at the synth (src 0=organ, 1=piano, 2=synth).
    private func ne6LayerFX(_ p: FwProgram, engine: String) -> PianoPlayer.LayerFX {
        var fx = PianoPlayer.LayerFX()
        func v(_ key: String) -> Double? { p.value(key).map(Double.init) }
        if engine == "synth" {
            if let freq = v("synth.fltFreq"), freq < 127 {
                fx.filterOn = true
                fx.filterNorm = freq / 127
                fx.filterType = Int(v("synth.fltType") ?? 0)
                fx.filterKeyTrack = (v("synth.fltKbdTrk") ?? 0) / 3
                // Velocity → cutoff ("filter dynamics").
                if v("synth.fltDyn") == 1 { fx.velToCutoff = (v("synth.fltVelAmt") ?? 0) / 127 }
            }
            if let atk = v("synth.ampEnvAtc") { fx.attackNorm = envAttackNorm(atk) }
            if let rls = v("synth.ampEnvRls") { fx.releaseTimeNorm = envReleaseNorm(rls) }
            if let vel = v("synth.ampEnvVel"), vel > 0 { fx.velToLevel = vel / 3 * 0.5 }
        }
        if let oct = v("\(engine).octaveShift") { fx.octaveShift = Int(oct) * 12 } // octaves → semitones
        if v("\(engine).sustainEnable") == 0 { fx.ignoresSustain = true }
        let src = engine == "synth" ? 2 : 1
        if v("effects.fx1Enable") == 1, v("effects.fx1Src") == Double(src) {
            fx.chorusOn = true
            fx.chorusRate = (v("effects.fx1Rate") ?? 0) / 127
            fx.chorusDepth = 0.5
        }
        // Effect 2 is the amp/speaker section on the hardware → our drive.
        if v("effects.fx2Enable") == 1, v("effects.fx2Src") == Double(src) {
            fx.driveOn = true
            fx.driveNorm = (v("effects.fx2Rate") ?? 0) / 127
        }
        if v("effects.dlyEnable") == 1, v("effects.dlySrc") == Double(src) {
            fx.delayOn = true
            fx.delayMix = (v("effects.dlyMix") ?? 0) / 127
            fx.delayTime = min(2, (v("effects.dlyRate") ?? 0) / 16383 * 2)
            fx.delayFeedback = (v("effects.dlyFeedback") ?? 0) / 3
        }
        if v("effects.eqlEnable") == 1, v("effects.eqlSrc") == Double(src) {
            fx.eqLow = (v("effects.eqlBass") ?? 0) / 60
            fx.eqMid = (v("effects.eqlMid") ?? 0) / 60
            fx.eqHigh = (v("effects.eqlTreble") ?? 0) / 60
        }
        if v("effects.rvbEnable") == 1 {
            fx.reverbOn = true
            fx.reverbMix = (v("effects.rvbAmt") ?? 0) / 127
            fx.reverbSize = (v("effects.rvbType") ?? 0) / 2
        }
        if v("effects.spkEnable") == 1, v("effects.spkSrc") == Double(src) {
            fx.driveOn = true
            fx.driveNorm = (v("effects.spkAmt") ?? 0) / 127
        }
        return fx
    }

    /// Map a decoded program's per-slot blocks onto our channel FX: voice mode,
    /// pitch stick, sustain switch, level/pan from MultiCommon, amp ADSR,
    /// filter (+type, key tracking, envelope, drive), morphs, 3-band EQ, LFO,
    /// vibrato, mod FX (approximated as chorus), delay and reverb. Missing
    /// fields keep the neutral defaults.
    private func nw2LayerFX(_ p: Nw2Program, slot: String) -> PianoPlayer.LayerFX {
        var fx = PianoPlayer.LayerFX()
        func v(_ key: String) -> Double? { p.value("slot\(slot)\(key)").map(Double.init) }
        // Voice mode 0=Poly 1=Mono 2=Legato (glide only applies in mono).
        if let mode = v("Common.voiceMode"), mode >= 1 {
            fx.monoOn = true
            fx.legato = mode == 2
            fx.glideNorm = (v("Common.glideRate") ?? 0) / 127
        }
        if v("Common.pitchStickEnable") == 0 {
            fx.bendUp = 0
            fx.bendDown = 0
        }
        fx.ignoresSustain = v("Common.sustainEnable") == 0
        if let pan = p.value("common.slotPan\(slot)") { fx.pan = Double(pan) / 60 }
        if let oct = v("Common.octaveShift") { fx.octaveShift = Int(oct) * 12 } // octaves → semitones
        if let atk = v("AmpEnv.ampEnvAtk") { fx.attackNorm = envAttackNorm(atk) }
        if let sus = v("AmpEnv.ampEnvSus"), sus < 127 {
            fx.ampSustain = sus / 127
            fx.ampDecay = (v("AmpEnv.ampEnvDcy") ?? 64) / 127
        }
        if let rls = v("AmpEnv.ampEnvRls") { fx.releaseTimeNorm = envReleaseNorm(rls) }
        if let vel = v("AmpEnv.ampEnvVel"), vel > 0 { fx.velToLevel = vel / 3 * 0.5 }
        if v("Filter.fltEnable") == 1 {
            fx.filterOn = true
            fx.filterType = Int(v("Filter.fltType") ?? 0)
            fx.filterNorm = (v("Filter.fltFreq") ?? 127) / 127
            if fx.filterType == SynthFilterType.lpHp.rawValue {
                fx.filterHPNorm = (v("Filter.fltRes") ?? 0) / 127
            } else {
                fx.filterRes = (v("Filter.fltRes") ?? 0) / 127
            }
            fx.filterKeyTrack = (v("Filter.fltKbdTrk") ?? 0) / 3
            let inverted = v("Filter.fltEnvInv") == 1
            fx.fltEnvAmt = (v("Filter.fltEnvAmt") ?? 0) / 127 * (inverted ? -1 : 1)
            fx.fltEnvAtk = (v("Filter.fltEnvAtk") ?? 0) / 127
            fx.fltEnvDcy = (v("Filter.fltEnvDcy") ?? 0) / 127
            fx.fltEnvSus = (v("Filter.fltEnvSus") ?? 127) / 127
            fx.fltEnvRls = (v("Filter.fltEnvRls") ?? 0) / 127
            fx.fltEnvVel = v("Filter.fltEnvVel") ?? 0
        }
        // Morphs: velocity → level; wheel/aftertouch/pedal → level and cutoff;
        // velocity → cutoff.
        fx.velToLevel = max(fx.velToLevel, morphDelta(p.value("common.slotLevel\(slot).morphVelocity")))
        applyLevelMorphs(p, key: "common.slotLevel\(slot)", pedal: "morphPedal", to: &fx)
        let cutoff = "slot\(slot)Filter.fltFreq"
        fx.wheelToCutoff = morphDelta(p.value("\(cutoff).morphWheel"))
        fx.atToCutoff = morphDelta(p.value("\(cutoff).morphAfterTouch"))
        fx.pedalToCutoff = morphDelta(p.value("\(cutoff).morphPedal"))
        fx.velToCutoff = morphDelta(p.value("\(cutoff).morphVelocity"))
        if let drive = v("Filter.fltDrive"), drive > 0 {
            fx.driveOn = true
            fx.driveNorm = drive / 3
        }
        if v("Eq.eqEnable") == 1 {
            fx.eqLow = (v("Eq.eqBass") ?? 0) / 60
            fx.eqMid = (v("Eq.eqMidGain") ?? 0) / 60
            fx.eqHigh = (v("Eq.eqTreble") ?? 0) / 60
            if let drive = v("Eq.eqDrive"), drive > 0 {
                fx.driveOn = true
                fx.driveNorm = max(fx.driveNorm, drive / 127)
            }
        }
        if v("Delay.dlyEnable") == 1 {
            fx.delayOn = true
            fx.delayMix = (v("Delay.dlyMix") ?? 0) / 127
            fx.delayFeedback = (v("Delay.dlyFbkAmt") ?? 0) / 127
            // Clock-divided rate → seconds approximation within our 0…2 s range.
            fx.delayTime = min(2, (v("Delay.dlyRateClkDiv") ?? 0) / 16383 * 2)
        }
        if v("Reverb.rvbEnable") == 1 {
            fx.reverbOn = true
            fx.reverbMix = (v("Reverb.rvbAmt") ?? 0) / 127
            fx.reverbSize = (v("Reverb.rvbType") ?? 0) / 4
        }
        // Mod FX (chorus/phaser/flanger family) — approximated by our chorus.
        if v("Fx.fxEnable") == 1 {
            fx.chorusOn = true
            fx.chorusDepth = (v("Fx.fxAmt") ?? 32) / 127
            fx.chorusRate = (v("Fx.fxRateClkDiv") ?? 38) / 127
        }
        // LFO (assumed same destination order as the Stage 4: 0=none 1=osc
        // ctrl 2=pitch 3=filter).
        if let amt = v("Lfo.lfoAmt"), amt > 0, let dst = v("Lfo.lfoDst"), dst >= 2 {
            fx.lfoDepth = amt / 127
            fx.lfoDest = dst == 2 ? SynthLfoDest.pitch.rawValue : SynthLfoDest.filter.rawValue
            fx.lfoShape = Int(v("Lfo.lfoWave") ?? 0)
            fx.lfoRate = (v("Lfo.lfoRateClkDiv") ?? 64) / 127
        }
        // Vibrato: pitch, with its own source mode (Stage 4 order assumed).
        fx.vibMode = Int(v("Common.vibratoMode") ?? 0)
        fx.vibDepth = (v("Vibrato.vibratoAmount") ?? 0) / 50
        fx.vibRate = (v("Vibrato.vibratoRate") ?? 30) / 60
        // Arpeggiator (direction field is `arpPattern` on the Wave 2).
        if v("Arp.arpRun") == 1 {
            fx.arpOn = true
            fx.arpMode = Int(v("Arp.arpMode") ?? 0)
            fx.arpDirection = Int(v("Arp.arpPattern") ?? 0)
            fx.arpOctaves = 1 + Int(((v("Arp.arpRange") ?? 0) / 127 * 3).rounded())
            fx.arpRate = (v("Arp.arpRateClkDiv") ?? 78) / 127
            fx.arpHold = v("Common.kbdHoldEnable") == 1 && p.value("common.kbdHold") == 1
        }
        return fx
    }

    /// What the importer would auto-pick for a file (name, category, subcategory)
    /// — the import review sheet pre-fills its pickers with this.
    func proposedClassification(for url: URL) -> (name: String, category: SoundCategory, subcategory: String?)? {
        guard let (name, _) = SoundCatalog.identity(of: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let folder = url.deletingLastPathComponent().lastPathComponent
        let category = SoundClassifier.category(ext: ext, name: name, sourceFolder: folder)
        let subcategory: String? = switch category {
        case .piano: SoundClassifier.pianoSubcategory(name: name)?.rawValue
        case .organ: SoundClassifier.organSubcategory(name: name)?.rawValue
        case .synth: SoundClassifier.synthSubcategory(name: name)?.rawValue
        case .orchestral: SoundClassifier.orchestralSubcategory(name: name)?.rawValue
        case .other: nil
        }
        return (name, category, subcategory)
    }

    func recategorize(_ entry: CatalogEntry, to category: SoundCategory, subcategory: String? = nil) {
        catalog.recategorize(entry, to: category, subcategory: subcategory)
        try? catalog.save()
    }

    /// Catalog entry for a loaded sound's URL, if the sound came from the catalog.
    func catalogEntry(for url: URL) -> CatalogEntry? {
        catalog.entries.first { $0.path == url.path }
    }

    /// The channel currently holding a sound of this engine category (the
    /// panel's "loaded slot" card), if any.
    func loadedChannel(in category: SoundCategory) -> ChannelState? {
        channels.first { catalogEntry(for: $0.entry.url)?.category == category }
    }

    /// Bridge a catalog entry to the library row model (URL-keyed selection).
    func pianoEntry(for entry: CatalogEntry) -> PianoEntry {
        PianoEntry(url: URL(fileURLWithPath: entry.path), name: entry.name,
                   version: entry.version, folder: "")
    }

    // MARK: - Scenes

    /// A saved setup: which sounds are layered, their mixer state and the master
    /// FX — recallable with one click (setlist-style).
    struct Scene: Identifiable, Codable {
        struct MasterFX: Codable, Hashable {
            var filterOn = false
            var filterNorm = 1.0
            var compOn = false
            var compAmount = 0.3
            var delayOn = false
            var delayTime = 0.25
            var delayFeedback = 0.3
            var delayMix = 0.2
            var reverbOn = false
            var reverbMix = 0.2
            var reverbSize = 0.4
            var boostDb = 0.0
        }
        var id = UUID()
        var name: String
        /// Bundle this scene came from (nil = user-created). Collections get
        /// their own fullscreen instead of flooding the scenes list.
        var collection: String? = nil
        /// Layer file paths, in the order they were selected.
        var sounds: [String]
        /// Catalog IDs parallel to `sounds` (nil element = sound not in the
        /// catalog). Resolution prefers the ID — immune to the managed library
        /// moving — and falls back to the path. Optional for pre-catalog scenes.
        var soundIDs: [UUID?]? = nil
        var gains: [String: Float] = [:]
        var muted: [String] = []
        var layerFX: [String: PianoPlayer.LayerFX] = [:]
        var fx = MasterFX()
    }

    @Published var scenes: [Scene] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(scenes), forKey: "scenes") }
    }
    /// The most recently recalled scene (highlighted on the perform page).
    @Published var activeSceneID: UUID?

    /// Snapshot of the current selection, mixer and master FX.
    private func captureScene(name: String) -> Scene {
        var fx = Scene.MasterFX()
        fx.filterOn = filterOn; fx.filterNorm = filterNorm
        fx.compOn = compOn; fx.compAmount = compAmount
        fx.delayOn = delayOn; fx.delayTime = delayTime
        fx.delayFeedback = delayFeedback; fx.delayMix = delayMix
        fx.reverbOn = reverbOn; fx.reverbMix = reverbMix; fx.reverbSize = reverbSize
        fx.boostDb = boostDb
        let urls = channels.map(\.entry.url) // channel order, not set order
        let catalogByPath = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.path, $0.id) })
        return Scene(
            name: name,
            sounds: urls.map(\.path),
            soundIDs: urls.map { catalogByPath[$0.path] },
            gains: Dictionary(uniqueKeysWithValues: urls.compactMap { u in gains[u].map { (u.path, $0) } }),
            muted: muted.map(\.path),
            layerFX: Dictionary(uniqueKeysWithValues: urls.compactMap { u in layerFX[u].map { (u.path, $0) } }),
            fx: fx)
    }

    /// Snapshot the current setup as a new named scene.
    func saveScene(name: String) {
        let scene = captureScene(name: name)
        scenes.append(scene)
        status = "Scene “\(name)” saved — \(scene.sounds.count) sound\(scene.sounds.count == 1 ? "" : "s")"
    }

    /// Overwrite a scene's contents with the current setup, keeping its name,
    /// id and position in the list.
    func updateScene(_ scene: Scene) {
        guard let i = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        var updated = captureScene(name: scene.name)
        updated.id = scene.id
        scenes[i] = updated
        status = "Scene “\(scene.name)” updated"
    }

    func renameScene(_ scene: Scene, to name: String) {
        guard let i = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[i].name = name
    }

    /// Recall a scene: restore its layers, mixer state and master FX. Sound files
    /// that no longer exist are skipped (and reported) rather than failing.
    func applyScene(_ scene: Scene) {
        var entries: [PianoEntry] = []
        var missing = 0
        for (i, storedPath) in scene.sounds.enumerated() {
            // Prefer the catalog ID: resolves to the entry's CURRENT path even
            // if the managed library moved since the scene was saved.
            let path: String
            if let id = scene.soundIDs?[safe: i] ?? nil,
               let entry = catalog.entries.first(where: { $0.id == id }) {
                path = entry.path
            } else {
                path = storedPath
            }
            if let entry = library.first(where: { $0.url.path == path }) {
                entries.append(entry)
            } else if let catalogEntry = catalog.entries.first(where: { $0.path == path }) {
                entries.append(pianoEntry(for: catalogEntry))
            } else if FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                entries.append(PianoEntry(url: url, name: url.deletingPathExtension().lastPathComponent,
                                          version: "", folder: ""))
            } else {
                missing += 1
            }
        }
        channels = entries.map { ChannelState(id: UUID(), entry: $0) }
        selectedChannelID = channels.first?.id
        for (path, gain) in scene.gains { gains[URL(fileURLWithPath: path)] = gain }
        muted = Set(scene.muted.map { URL(fileURLWithPath: $0) })
        for (path, fx) in scene.layerFX { layerFX[URL(fileURLWithPath: path)] = fx }
        let fx = scene.fx
        filterOn = fx.filterOn; filterNorm = fx.filterNorm
        compOn = fx.compOn; compAmount = fx.compAmount
        delayOn = fx.delayOn; delayTime = fx.delayTime
        delayFeedback = fx.delayFeedback; delayMix = fx.delayMix
        reverbOn = fx.reverbOn; reverbMix = fx.reverbMix; reverbSize = fx.reverbSize
        boostDb = fx.boostDb
        syncLayers()
        // syncLayers only pushes gain/mute/FX to newly added layers — refresh all.
        if let player {
            for channel in channels {
                player.setLayerGain(gains[channel.entry.url] ?? 1, id: channel.id)
                player.setLayerMuted(muted.contains(channel.entry.url), id: channel.id)
                player.setLayerFX(layerFX[channel.entry.url] ?? PianoPlayer.LayerFX(), id: channel.id)
                applyDrawbars(layerFX[channel.entry.url] ?? PianoPlayer.LayerFX(), for: channel)
            }
        }
        status = missing == 0
            ? "Scene “\(scene.name)” — \(entries.count) sound\(entries.count == 1 ? "" : "s")"
            : "Scene “\(scene.name)” loaded — \(missing) sound\(missing == 1 ? "" : "s") missing"
        activeSceneID = scene.id
    }

    /// Index of the active scene in the user-scene list (nil if none recalled).
    var activeSceneIndex: Int? { userScenes.firstIndex { $0.id == activeSceneID } }

    /// Step through the user scenes (header ◀ ▶). With no active scene, ▶ starts
    /// at the first and ◀ at the last; wraps around.
    func stepScene(_ delta: Int) {
        let list = userScenes
        guard !list.isEmpty else { return }
        let current = activeSceneIndex ?? (delta > 0 ? -1 : 0)
        let next = (current + delta + list.count) % list.count
        applyScene(list[next])
    }

    func deleteScene(_ scene: Scene) {
        scenes.removeAll { $0.id == scene.id }
    }

    func moveScenes(from offsets: IndexSet, to destination: Int) {
        scenes.move(fromOffsets: offsets, toOffset: destination)
    }

    // MARK: - Devices

    @Published var audioDevices: [PianoPlayer.AudioDevice] = []
    /// kAudioDeviceUnknown = system default output.
    @Published var audioDeviceID: AudioDeviceID = AudioDeviceID(UserDefaults.standard.integer(forKey: "audioDeviceID")) {
        didSet { UserDefaults.standard.set(Int(audioDeviceID), forKey: "audioDeviceID"); applyDevices() }
    }
    @Published var midiInputs: [PianoPlayer.MidiInput] = []
    /// Endpoint 0 = all sources.
    @Published var midiSourceID: MIDIEndpointRef = MIDIEndpointRef(UserDefaults.standard.integer(forKey: "midiSourceID")) {
        didSet { UserDefaults.standard.set(Int(midiSourceID), forKey: "midiSourceID"); applyDevices() }
    }

    /// Snapshot the system's audio outputs and MIDI sources.
    func refreshDevices() {
        audioDevices = [PianoPlayer.AudioDevice(id: kAudioDeviceUnknown, name: "System Default")]
            + PianoPlayer.audioOutputDevices()
        midiInputs = [PianoPlayer.MidiInput(id: 0, name: "All Sources")] + (player?.midiInputs() ?? [])
        if !audioDevices.contains(where: { $0.id == audioDeviceID }) { audioDeviceID = kAudioDeviceUnknown }
        if !midiInputs.contains(where: { $0.id == midiSourceID }) { midiSourceID = 0 }
    }

    private func applyDevices() {
        // kAudioDeviceUnknown means "system default" — leave the engine's output
        // alone; pushing 0 into CurrentDevice halts a running engine.
        if audioDeviceID != kAudioDeviceUnknown {
            try? player?.setAudioOutputDevice(audioDeviceID)
        }
        player?.selectMidiSource(midiSourceID)
    }

    init() {
        roots = (UserDefaults.standard.array(forKey: "libraryRoots") as? [String] ?? [])
            .map(URL.init(fileURLWithPath:))
        favorites = ((UserDefaults.standard.array(forKey: "favoritePianos") as? [[String: String]]) ?? [])
            .compactMap { d in
                guard let path = d["path"], FileManager.default.fileExists(atPath: path) else { return nil }
                return PianoEntry(url: URL(fileURLWithPath: path), name: d["name"] ?? "Piano",
                                  version: d["version"] ?? "", folder: "")
            }
        if let data = UserDefaults.standard.data(forKey: "layerFX"),
           let saved = try? JSONDecoder().decode([String: PianoPlayer.LayerFX].self, from: data) {
            layerFX = Dictionary(uniqueKeysWithValues: saved.map { (URL(fileURLWithPath: $0.key), $0.value) })
        }
        if let data = UserDefaults.standard.data(forKey: "scenes"),
           let saved = try? JSONDecoder().decode([Scene].self, from: data) {
            scenes = saved
        }
        rescan()
    }

    private func persistLayerFX() {
        let dict = Dictionary(uniqueKeysWithValues: layerFX.map { ($0.key.path, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(dict), forKey: "layerFX")
    }

    /// Mixer strip change: EQ, filter, compressor or reverb of one channel.
    /// The FX is remembered per sound (path-keyed) so it follows the sound
    /// into any channel or scene.
    func setLayerFX(_ fx: PianoPlayer.LayerFX, for channel: ChannelState) {
        layerFX[channel.entry.url] = fx
        player?.setLayerFX(fx, id: channel.id)
        applyDrawbars(fx, for: channel)
    }

    // MARK: - Drawbars (gated SFZ organs)

    /// The gate CCs of a channel's SFZ program (empty = not a drawbar organ).
    func drawbarCCs(for channel: ChannelState) -> [Int] {
        player?.layerGateCCs(id: channel.id) ?? []
    }

    /// Push a LayerFX's drawbar positions into the engine's gate state.
    private func applyDrawbars(_ fx: PianoPlayer.LayerFX, for channel: ChannelState) {
        guard let player, !fx.drawbars.isEmpty else { return }
        let ccs = player.layerGateCCs(id: channel.id)
        for (index, position) in fx.drawbars.enumerated() where index < ccs.count {
            player.setLayerGateValue(Int((position / 8) * 127), cc: ccs[index], id: channel.id)
        }
    }

    /// Move one drawbar (0…8) of a channel; persists with the sound's FX state.
    func setDrawbar(_ index: Int, position: Double, for channel: ChannelState) {
        var fx = layerFX[channel.entry.url] ?? PianoPlayer.LayerFX()
        let ccs = drawbarCCs(for: channel)
        guard index < ccs.count else { return }
        if fx.drawbars.count < ccs.count { fx.drawbars += repeatElement(0, count: ccs.count - fx.drawbars.count) }
        fx.drawbars[index] = position
        layerFX[channel.entry.url] = fx
        player?.setLayerGateValue(Int((position / 8) * 127), cc: ccs[index], id: channel.id)
    }

    /// Initial drawbar positions for a channel: the sound's saved FX if any,
    /// else the program's <control> defaults — or the classic 888000000 when
    /// the program defaults everything to silent (HamOrg does).
    func initialDrawbars(for channel: ChannelState) -> [Double] {
        let ccs = drawbarCCs(for: channel)
        guard !ccs.isEmpty, let player else { return [] }
        if let saved = layerFX[channel.entry.url]?.drawbars, saved.count == ccs.count {
            return saved
        }
        let defaults = ccs.map { Double(player.layerGateValue(cc: $0, id: channel.id)) / 127 * 8 }
        return defaults.allSatisfy { $0 == 0 }
            ? [8, 8, 8] + repeatElement(0, count: max(0, ccs.count - 3))
            : defaults
    }

    /// Read just enough of a file for its identity — pianos are tens of MB.
    private func identity(of url: URL) -> (name: String, version: String)? {
        let ext = url.pathExtension.lowercased()
        guard ["npno", "nsmp3", "nsmp4", "sfz", "sf2"].contains(ext) else { return nil }
        if ext == "sfz" {
            guard !SfzParser.parseFile(url).regions.isEmpty else { return nil }
            return (url.deletingPathExtension().lastPathComponent, "")
        }
        if ext == "sf2" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            let head = (try? handle.read(upToCount: 12)) ?? Data()
            try? handle.close()
            guard isSoundFont(bytes: [UInt8](head)) else { return nil }
            return (url.deletingPathExtension().lastPathComponent, "")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2048), head.count > 0x67 else { return nil }
        let bytes = [UInt8](head)
        let fallback = url.deletingPathExtension().lastPathComponent
        if ext == "npno" {
            guard let id = readNspIdentity(bytes) else { return nil }
            return (id.name ?? fallback, id.version)
        }
        let id = identifyNsmp(bytes)
        guard id.recognized, !id.legacy else { return nil }
        return (readNsmpName(bytes) ?? fallback, id.version ?? "")
    }

    /// Full header read (name/version/zones of the loaded sound).
    private func fullIdentity(of url: URL) -> (name: String, version: String, zones: Int)? {
        let fallback = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "sfz" {
            let regions = SfzParser.parseFile(url).regions
            guard !regions.isEmpty else { return nil }
            return (fallback, "", regions.count)
        }
        if url.pathExtension.lowercased() == "sf2" {
            guard identity(of: url) != nil else { return nil }
            // Zone count lives inside the sampler (AUSampler owns the bank).
            return (fallback, "", 1)
        }
        let bytes = [UInt8]((try? Data(contentsOf: url)) ?? Data())
        if url.pathExtension.lowercased() == "npno" {
            guard let dir = try? readNspDirectory(bytes) else { return nil }
            let id = readNspIdentity(bytes)
            return (id?.name ?? fallback, id?.version ?? "", readNspZones(bytes).count)
        }
        let id = identifyNsmp(bytes)
        guard id.recognized, !id.legacy else { return nil }
        return (readNsmpName(bytes) ?? fallback, id.version ?? "", readNsmpZones(bytes).count)
    }

    // MARK: - Library roots

    /// Add a folder to the library and scan everything (existing roots stay).
    func addFolder(_ url: URL) {
        if !roots.contains(url) {
            roots.append(url)
            UserDefaults.standard.set(roots.map(\.path), forKey: "libraryRoots")
        }
        rescan()
    }

    func removeFolder(_ url: URL) {
        roots.removeAll { $0 == url }
        UserDefaults.standard.set(roots.map(\.path), forKey: "libraryRoots")
        rescan()
    }

    /// Sidebar sections: Shortcuts first, then each root grouped by containing folder.
    var sections: [(title: String, entries: [PianoEntry])] {
        var out: [(String, [PianoEntry])] = []
        if !favorites.isEmpty { out.append(("★ SHORTCUTS", favorites)) }
        for root in roots {
            let inRoot = library.filter { $0.url.path.hasPrefix(root.path) }
            var groups: [String: [PianoEntry]] = [:]
            for e in inRoot {
                let parent = e.url.deletingLastPathComponent().path
                let rel = parent.hasPrefix(root.path)
                    ? String(parent.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    : parent
                let key = rel.isEmpty ? root.lastPathComponent : "\(root.lastPathComponent) / \(rel)"
                groups[key, default: []].append(e)
            }
            for key in groups.keys.sorted() {
                out.append((key, groups[key]!.sorted { $0.name < $1.name }))
            }
        }
        return out
    }

    private func rescan() {
        var seen = Set<URL>()
        var entries: [PianoEntry] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let file as URL in enumerator where ["npno", "nsmp3", "nsmp4", "sfz", "sf2"].contains(file.pathExtension.lowercased()) {
                if seen.insert(file).inserted, let id = identity(of: file) {
                    entries.append(PianoEntry(url: file, name: id.name, version: id.version, folder: ""))
                }
            }
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        library = entries
        // Drop channels whose sound vanished.
        channels = channels.filter { ch in
            entries.contains(ch.entry) || FileManager.default.fileExists(atPath: ch.entry.url.path)
        }
        if channels.isEmpty, let first = entries.first { channels = [ChannelState(id: UUID(), entry: first)] }
        status = roots.isEmpty
            ? "Add a folder (+ in the library sidebar), or drop a .npno / .nsmp4"
            : "\(entries.count) sounds in \(roots.count) folder\(roots.count == 1 ? "" : "s") — click to play, click again to layer"
        syncLayers()
    }

    // MARK: - Favorites

    func isFavorite(_ entry: PianoEntry) -> Bool { favorites.contains(entry) }

    func toggleFavorite(_ entry: PianoEntry) {
        if favorites.contains(entry) {
            favorites.removeAll { $0 == entry }
        } else {
            favorites.insert(entry, at: 0)
        }
        UserDefaults.standard.set(
            favorites.map { ["path": $0.url.path, "name": $0.name, "version": $0.version] },
            forKey: "favoritePianos")
    }

    // MARK: - Selection / channels

    /// Toggle a sound in the mix: if a channel already holds it, remove that
    /// channel; otherwise append a new channel at the end.
    func select(_ entry: PianoEntry) {
        if let i = channels.firstIndex(where: { $0.entry == entry }) {
            removeChannel(channels[i])
        } else {
            channels.append(ChannelState(id: UUID(), entry: entry))
            syncLayers()
        }
        activeSceneID = nil // hand-picked layers no longer match any recalled scene
    }

    /// Assign a sound to the selected channel (replacing its current sound), or
    /// append it as a new channel when nothing is selected.
    func assignToChannel(_ entry: PianoEntry) {
        if let id = selectedChannelID, let i = channels.firstIndex(where: { $0.id == id }) {
            if channels[i].entry == entry { return }
            channels[i].entry = entry
            // Same slot, new sound: the engine layer must be rebuilt.
            player?.removeLayer(id: id)
        } else {
            let channel = ChannelState(id: UUID(), entry: entry)
            channels.append(channel)
            selectedChannelID = channel.id
        }
        activeSceneID = nil
        syncLayers()
    }

    func removeChannel(_ channel: ChannelState) {
        channels.removeAll { $0.id == channel.id }
        if selectedChannelID == channel.id { selectedChannelID = channels.first?.id }
        syncLayers()
    }

    /// The catalog list a channel can step through (same category, panel order),
    /// plus its current index. Nil when the sound isn't in the catalog.
    func browseContext(for channel: ChannelState) -> (entries: [CatalogEntry], index: Int)? {
        guard let entry = catalogEntry(for: channel.entry.url) else { return nil }
        let list = catalog.entries(in: entry.category)
        guard let index = list.firstIndex(where: { $0.id == entry.id }) else { return nil }
        return (list, index)
    }

    /// Swap a channel's sound in place (same slot, engine layer rebuilt).
    private func replaceSound(of channel: ChannelState, with entry: PianoEntry) {
        guard let i = channels.firstIndex(where: { $0.id == channel.id }),
              channels[i].entry != entry else { return }
        channels[i].entry = entry
        player?.removeLayer(id: channel.id)
        activeSceneID = nil
        syncLayers()
    }

    /// Step to the previous/next catalog sound in the channel's category
    /// (wraps around) — the channel strip's browse popover.
    func stepChannelSound(_ channel: ChannelState, delta: Int) {
        guard let (list, index) = browseContext(for: channel) else { return }
        let next = (index + delta + list.count) % list.count
        replaceSound(of: channel, with: pianoEntry(for: list[next]))
    }

    func setGain(_ gain: Float, for channel: ChannelState) {
        gains[channel.entry.url] = gain
        player?.setLayerGain(gain, id: channel.id)
    }

    func toggleMute(_ channel: ChannelState) {
        let url = channel.entry.url
        let isMuted = !muted.contains(url)
        if isMuted { muted.insert(url) } else { muted.remove(url) }
        player?.setLayerMuted(isMuted, id: channel.id)
    }

    private func syncLayers() {
        do {
            if player == nil {
                player = PianoPlayer()
                wirePlayerCallbacks()
                try player?.start()
                refreshDevices()
                applyDevices()
                applyFX()
            }
            guard let player else { return }
            let wanted = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0.entry) })
            let have = Set(player.layerIDs)
            for (id, entry) in wanted where !have.contains(id) {
                // .sf2 loads into AUSampler by URL — never read into memory
                // (SoundFonts run to hundreds of MB).
                let bytes = entry.url.pathExtension.lowercased() == "sf2"
                    ? [] : [UInt8](try Data(contentsOf: entry.url))
                try addToPlayer(player, bytes: bytes, url: entry.url, id: id, gain: gains[entry.url] ?? 1)
                player.setLayerFX(layerFX[entry.url] ?? PianoPlayer.LayerFX(), id: id)
                // Drawbar organ with no saved positions: seed the classic 888
                // registration (program defaults may be all-silent).
                if !player.layerGateCCs(id: id).isEmpty,
                   layerFX[entry.url]?.drawbars.isEmpty != false {
                    let channel = ChannelState(id: id, entry: entry)
                    var fx = layerFX[entry.url] ?? PianoPlayer.LayerFX()
                    fx.drawbars = initialDrawbars(for: channel)
                    layerFX[entry.url] = fx
                    applyDrawbars(fx, for: channel)
                } else if let fx = layerFX[entry.url], !fx.drawbars.isEmpty {
                    applyDrawbars(fx, for: ChannelState(id: id, entry: entry))
                }
                if muted.contains(entry.url) { player.setLayerMuted(true, id: id) }
            }
            for id in have.subtracting(wanted.keys) { player.removeLayer(id: id) }
            updateHeader()
        } catch {
            status = "Error: \(error)"
            print("nordpiano: syncLayers error: \(error)")
        }
    }

    /// Add a file to the player, picking the decoder by extension (piano vs sample
    /// vs SFZ vs SoundFont). The layer id is the channel slot; the url picks the
    /// decoder — SFZ needs it to resolve its sample paths, SF2 loads by URL.
    private func addToPlayer(_ player: PianoPlayer, bytes: [UInt8], url: URL, id: UUID, gain: Float) throws {
        switch url.pathExtension.lowercased() {
        case "npno": try player.addLayer(bytes: bytes, id: id, gain: gain)
        case "sfz": try player.addSfzLayer(url: url, id: id, gain: gain)
        case "sf2": try player.addSoundFontLayer(url: url, id: id, gain: gain)
        default: try player.addSampleLayer(bytes: bytes, id: id, gain: gain)
        }
    }

    private func refreshMarkers() {
        markers = player?.markers ?? []
    }

    private func updateHeader() {
        refreshMarkers()
        guard let first = channels.sorted(by: { $0.entry.name < $1.entry.name }).first,
              let info = fullIdentity(of: first.entry.url) else {
            pianoTitle = "No piano loaded"
            version = ""
            return
        }
        pianoTitle = info.name
        version = info.version
        status = channels.count > 1
            ? "Layering \(channels.count) sounds — \(info.zones) zones in \(first.entry.name)"
            : "Playing — \(info.zones) zones. MIDI in, built-in audio out."
    }

    private func applyFX() {
        let cutoff = 200 * pow(90, filterNorm)
        player?.setFilter(enabled: filterOn, cutoffHz: cutoff)
        player?.setCompressor(amount: compOn ? compAmount : 0)
        player?.setMasterDelay(enabled: delayOn, timeSeconds: delayTime,
                               feedback: delayFeedback, mix: delayMix)
        player?.setMasterBoost(dB: Float(boostDb))
        player?.setReverb(mix: reverbOn ? reverbMix : 0, decaySeconds: 0.3 + reverbSize * 6.7)
    }

    /// Replace all channels with a single sound (drop / Open…).
    func load(url: URL) {
        if isBundle(url) {
            importBundle(url: url)
            return
        }
        if let entry = library.first(where: { $0.url == url }) {
            channels = [ChannelState(id: UUID(), entry: entry)]
            syncLayers()
            return
        }
        guard let info = fullIdentity(of: url) else {
            status = "Can't read \(url.lastPathComponent)"
            return
        }
        if player == nil {
            _ = try? ensureEngine()
        }
        guard let player else { return }
        for id in player.layerIDs { player.removeLayer(id: id) }
        let id = UUID()
        do {
            // .sf2 loads into AUSampler by URL — never read into memory.
            let bytes = url.pathExtension.lowercased() == "sf2"
                ? [] : [UInt8](try Data(contentsOf: url))
            try addToPlayer(player, bytes: bytes, url: url, id: id, gain: 1)
            player.setLayerFX(layerFX[url] ?? PianoPlayer.LayerFX(), id: id)
        } catch {
            status = "Error: \(error)"
            return
        }
        channels = [ChannelState(id: id, entry: PianoEntry(url: url, name: info.name, version: info.version, folder: ""))]
        pianoTitle = info.name
        version = info.version
        refreshMarkers()
        status = "Playing — \(info.zones) sampled zones. MIDI in, built-in audio out."
    }

    /// Engine → UI callbacks (created in both engine-start paths).
    private func wirePlayerCallbacks() {
        player?.soundingNotesHandler = { [weak self] notes in
            MainActor.assumeIsolated { self?.sounding = notes }
        }
        player?.midiActivityHandler = { [weak self] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.midiActivity = text }
            }
        }
    }

    @discardableResult
    private func ensureEngine() throws -> Bool {
        if player == nil {
            player = PianoPlayer()
            wirePlayerCallbacks()
            try player?.start()
            refreshDevices()
            applyDevices()
            applyFX()
            return true
        }
        return false
    }

    // MARK: - Recording

    @Published var isRecording = false
    /// Seconds since the current take started (UI readout).
    @Published var recordingSeconds = 0
    /// The most recent finished take (shown in the take bar for playback).
    @Published var lastTake: URL?
    @Published var isPlayingTake = false
    /// Per-buffer peaks of the recording — the take bar's waveform (capped).
    @Published var recordLevels: [Float] = []
    private var recordTimer: Timer?
    private var recordURL: URL?

    /// Toggle a take: start recording the master bus to a timestamped WAV in
    /// ~/Music/nordpiano, or stop and keep the file. Starts the engine if needed
    /// so a take can begin before any sound is loaded (it records silence).
    func toggleRecording() {
        if isRecording {
            player?.stopRecording()
            recordTimer?.invalidate()
            recordTimer = nil
            isRecording = false
            lastTake = recordURL
            status = "Take saved to ~/Music/nordpiano"
            return
        }
        do {
            _ = try ensureEngine()
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music/nordpiano", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "")
            let url = dir.appendingPathComponent("take-\(stamp).wav")
            player?.stopTake()
            isPlayingTake = false
            lastTake = nil
            recordLevels = []
            player?.recordLevelHandler = { [weak self] level in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isRecording else { return }
                        self.recordLevels.append(level)
                        if self.recordLevels.count > 1200 { self.recordLevels.removeFirst(self.recordLevels.count - 1200) }
                    }
                }
            }
            try player?.startRecording(to: url)
            recordURL = url
            recordingSeconds = 0
            isRecording = true
            status = "Recording — \(url.lastPathComponent)"
            recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordingSeconds += 1 }
            }
        } catch {
            status = "Record error: \(error.localizedDescription)"
        }
    }

    /// Play/stop the last take. Routes through the main mixer, so any master FX
    /// currently on are applied again on top of the ones baked into the take.
    func toggleTakePlayback() {
        if isPlayingTake {
            player?.stopTake()
            isPlayingTake = false
            return
        }
        guard let url = lastTake else { return }
        player?.takeEndedHandler = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.player?.stopTake()
                    self?.isPlayingTake = false
                }
            }
        }
        do {
            try player?.playTake(url: url)
            isPlayingTake = true
        } catch {
            status = "Playback error: \(error.localizedDescription)"
        }
    }

    /// Show the saved take in Finder.
    func revealTake() {
        if let lastTake { NSWorkspace.shared.activateFileViewerSelecting([lastTake]) }
    }

    /// Close the take bar (the file stays in ~/Music/nordpiano).
    func dismissTake() {
        player?.stopTake()
        isPlayingTake = false
        lastTake = nil
        recordLevels = []
    }

    func noteOn(_ note: Int) {
        uiHeld.insert(note)
        player?.noteOn(note, velocity: Int(velocity))
    }

    func noteOff(_ note: Int) {
        uiHeld.remove(note)
        player?.noteOff(note)
    }
}
