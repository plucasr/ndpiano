import Foundation
import SwiftUI
import CoreAudio
import CoreMIDI
import NordPianoCore
import NordPianoEngine

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
    @Published var releaseGain: Double = 0.5 { didSet { player?.setReleaseGain(Float(releaseGain)) } }
    @Published var sounding: Set<Int> = []
    @Published var status = "Drop a .npno or .nsmp4 file anywhere, or Open…"
    @Published var roots: [URL] = []
    @Published var library: [PianoEntry] = []
    @Published var selected: Set<PianoEntry> = []
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
        rescan()
    }

    private func persistLayerFX() {
        let dict = Dictionary(uniqueKeysWithValues: layerFX.map { ($0.key.path, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(dict), forKey: "layerFX")
    }

    /// Mixer strip change: EQ, filter, compressor or reverb of one layer.
    func setLayerFX(_ fx: PianoPlayer.LayerFX, for url: URL) {
        layerFX[url] = fx
        player?.setLayerFX(fx, id: url)
    }

    /// Read just enough of a file for its identity — pianos are tens of MB.
    private func identity(of url: URL) -> (name: String, version: String)? {
        let ext = url.pathExtension.lowercased()
        guard ["npno", "nsmp3", "nsmp4"].contains(ext) else { return nil }
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
            for case let file as URL in enumerator where ["npno", "nsmp3", "nsmp4"].contains(file.pathExtension.lowercased()) {
                if seen.insert(file).inserted, let id = identity(of: file) {
                    entries.append(PianoEntry(url: file, name: id.name, version: id.version, folder: ""))
                }
            }
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        library = entries
        // Drop selections/favorites that vanished.
        selected = selected.filter { sel in entries.contains(sel) || FileManager.default.fileExists(atPath: sel.url.path) }
        if selected.isEmpty, let first = entries.first { selected = [first] }
        status = roots.isEmpty
            ? "Add a folder (Folder…), or drop a .npno / .nsmp4"
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

    // MARK: - Selection / layering

    func select(_ entry: PianoEntry) {
        if selected.contains(entry) { selected.remove(entry) } else { selected.insert(entry) }
        syncLayers()
    }

    func setGain(_ gain: Float, for entry: PianoEntry) {
        gains[entry.url] = gain
        player?.setLayerGain(gain, id: entry.url)
    }

    func toggleMute(_ entry: PianoEntry) {
        let isMuted = !muted.contains(entry.url)
        if isMuted { muted.insert(entry.url) } else { muted.remove(entry.url) }
        player?.setLayerMuted(isMuted, id: entry.url)
    }

    private func syncLayers() {
        do {
            if player == nil {
                player = PianoPlayer()
                player?.soundingNotesHandler = { [weak self] notes in
                    MainActor.assumeIsolated { self?.sounding = notes }
                }
                try player?.start()
                refreshDevices()
                applyDevices()
                applyFX()
            }
            guard let player else { return }
            let wanted = Set(selected.map(\.url))
            let have = Set(player.layerIDs)
            for url in wanted.subtracting(have) {
                let data = try Data(contentsOf: url)
                try addToPlayer(player, bytes: [UInt8](data), url: url, gain: gains[url] ?? 1)
                player.setLayerFX(layerFX[url] ?? PianoPlayer.LayerFX(), id: url)
                if muted.contains(url) { player.setLayerMuted(true, id: url) }
            }
            for url in have.subtracting(wanted) { player.removeLayer(id: url) }
            updateHeader()
        } catch {
            status = "Error: \(error)"
            print("nordpiano: syncLayers error: \(error)")
        }
    }

    /// Add a file to the player, picking the decoder by extension (piano vs sample).
    private func addToPlayer(_ player: PianoPlayer, bytes: [UInt8], url: URL, gain: Float) throws {
        if url.pathExtension.lowercased() == "npno" {
            try player.addLayer(bytes: bytes, id: url, gain: gain)
        } else {
            try player.addSampleLayer(bytes: bytes, id: url, gain: gain)
        }
    }

    private func refreshMarkers() {
        markers = player?.markers ?? []
    }

    private func updateHeader() {
        refreshMarkers()
        guard let first = selected.sorted(by: { $0.name < $1.name }).first,
              let info = fullIdentity(of: first.url) else {
            pianoTitle = "No piano loaded"
            version = ""
            return
        }
        pianoTitle = info.name
        version = info.version
        status = selected.count > 1
            ? "Layering \(selected.count) sounds — \(info.zones) zones in \(first.name)"
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

    /// Replace all layers with a single piano (drop / Open…).
    func load(url: URL) {
        if let entry = library.first(where: { $0.url == url }) {
            selected = [entry]
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
        do {
            let data = try Data(contentsOf: url)
            try addToPlayer(player, bytes: [UInt8](data), url: url, gain: 1)
            player.setLayerFX(layerFX[url] ?? PianoPlayer.LayerFX(), id: url)
        } catch {
            status = "Error: \(error)"
            return
        }
        selected = []
        pianoTitle = info.name
        version = info.version
        refreshMarkers()
        status = "Playing — \(info.zones) sampled zones. MIDI in, built-in audio out."
    }

    @discardableResult
    private func ensureEngine() throws -> Bool {
        if player == nil {
            player = PianoPlayer()
            player?.soundingNotesHandler = { [weak self] notes in
                MainActor.assumeIsolated { self?.sounding = notes }
            }
            try player?.start()
            refreshDevices()
            applyDevices()
            applyFX()
            return true
        }
        return false
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
