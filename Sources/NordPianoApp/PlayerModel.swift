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
    /// name heuristics). Misclassified entries can be moved afterwards.
    func importSounds(_ urls: [URL]) {
        var ok = 0
        for url in urls {
            do {
                _ = try catalog.importFile(at: url)
                ok += 1
            } catch {
                status = "Import error: \(error.localizedDescription)"
            }
        }
        try? catalog.save()
        if ok > 0 { status = "Imported \(ok) sound\(ok == 1 ? "" : "s") into the library" }
    }

    func recategorize(_ entry: CatalogEntry, to category: SoundCategory, subcategory: PianoSubcategory? = nil) {
        catalog.recategorize(entry, to: category, subcategory: subcategory)
        try? catalog.save()
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
            }
        }
        status = missing == 0
            ? "Scene “\(scene.name)” — \(entries.count) sound\(entries.count == 1 ? "" : "s")"
            : "Scene “\(scene.name)” loaded — \(missing) sound\(missing == 1 ? "" : "s") missing"
        activeSceneID = scene.id
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
                player?.soundingNotesHandler = { [weak self] notes in
                    MainActor.assumeIsolated { self?.sounding = notes }
                }
                try player?.start()
                refreshDevices()
                applyDevices()
                applyFX()
            }
            guard let player else { return }
            let wanted = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0.entry) })
            let have = Set(player.layerIDs)
            for (id, entry) in wanted where !have.contains(id) {
                let data = try Data(contentsOf: entry.url)
                try addToPlayer(player, bytes: [UInt8](data), url: entry.url, id: id, gain: gains[entry.url] ?? 1)
                player.setLayerFX(layerFX[entry.url] ?? PianoPlayer.LayerFX(), id: id)
                if muted.contains(entry.url) { player.setLayerMuted(true, id: id) }
            }
            for id in have.subtracting(wanted.keys) { player.removeLayer(id: id) }
            updateHeader()
        } catch {
            status = "Error: \(error)"
            print("nordpiano: syncLayers error: \(error)")
        }
    }

    /// Add a file to the player, picking the decoder by extension (piano vs sample).
    /// The layer id is the channel slot; the url only picks the decoder.
    private func addToPlayer(_ player: PianoPlayer, bytes: [UInt8], url: URL, id: UUID, gain: Float) throws {
        if url.pathExtension.lowercased() == "npno" {
            try player.addLayer(bytes: bytes, id: id, gain: gain)
        } else {
            try player.addSampleLayer(bytes: bytes, id: id, gain: gain)
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
            let data = try Data(contentsOf: url)
            try addToPlayer(player, bytes: [UInt8](data), url: url, id: id, gain: 1)
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
