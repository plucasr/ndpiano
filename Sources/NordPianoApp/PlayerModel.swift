import Foundation
import SwiftUI
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
        var kind: String { url.pathExtension.lowercased() == "npno" ? "PIANO" : "SAMPLE" }
    }

    @Published var pianoTitle = "No piano loaded"
    @Published var version = ""
    @Published var velocity: Double = 80
    @Published var sounding: Set<Int> = []
    @Published var status = "Drop a .npno file anywhere, or Open…"
    @Published var roots: [URL] = []
    @Published var library: [PianoEntry] = []
    @Published var selected: Set<PianoEntry> = []
    @Published var gains: [URL: Float] = [:]
    @Published var favorites: [PianoEntry] = []

    // FX
    @Published var filterOn = false { didSet { applyFX() } }
    @Published var filterNorm: Double = 1 { didSet { applyFX() } }
    @Published var compOn = false { didSet { applyFX() } }
    @Published var compAmount: Double = 0.3 { didSet { applyFX() } }
    @Published var reverbOn = false { didSet { applyFX() } }
    @Published var reverbMix: Double = 0.2 { didSet { applyFX() } }
    @Published var reverbSize: Double = 0.4 { didSet { applyFX() } }

    private(set) var player: PianoPlayer?
    @Published var markers: [Int] = []
    /// Keys pressed on screen (so the keyboard shows UI touches even before voices sound).
    @Published var uiHeld: Set<Int> = []

    init() {
        roots = (UserDefaults.standard.array(forKey: "libraryRoots") as? [String] ?? [])
            .map(URL.init(fileURLWithPath:))
        favorites = ((UserDefaults.standard.array(forKey: "favoritePianos") as? [[String: String]]) ?? [])
            .compactMap { d in
                guard let path = d["path"], FileManager.default.fileExists(atPath: path) else { return nil }
                return PianoEntry(url: URL(fileURLWithPath: path), name: d["name"] ?? "Piano",
                                  version: d["version"] ?? "", folder: "")
            }
        rescan()
    }

    /// Read just enough of a file for its identity — pianos are tens of MB.
    /// Samples fall back to the file name (their metadata needs a full parse).
    private func identity(of url: URL) -> (name: String, version: String)? {
        if url.pathExtension.lowercased() == "npno" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: 2048), head.count > 0x67 else { return nil }
            guard let id = readNspIdentity([UInt8](head)) else { return nil }
            return (id.name ?? url.deletingPathExtension().lastPathComponent, id.version)
        }
        return (url.deletingPathExtension().lastPathComponent, "")
    }

    /// Full header read (name/version/zones of the loaded file, piano or sample).
    private func fullIdentity(of url: URL) -> (name: String, version: String, zones: Int)? {
        let fallback = url.deletingPathExtension().lastPathComponent
        let bytes = [UInt8]((try? Data(contentsOf: url)) ?? Data())
        if url.pathExtension.lowercased() == "npno" {
            guard let dir = try? readNspDirectory(bytes) else { return nil }
            let id = readNspIdentity(bytes)
            return (id?.name ?? fallback, id?.version ?? "", readNspZones(bytes).count)
        }
        guard let f = try? NsmpBridge.shared.load(bytes: bytes) else { return nil }
        NsmpBridge.shared.release(handle: f.handle)
        return (f.name.isEmpty ? fallback : f.name, f.version, f.zones.count)
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
            for case let file as URL in enumerator where ["npno", "nsmp", "nsmp3", "nsmp4"].contains(file.pathExtension.lowercased()) {
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
            ? "Add a folder (Folder…) or drop a .npno"
            : "\(entries.count) pianos in \(roots.count) folder\(roots.count == 1 ? "" : "s") — click to play, click again to layer"
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

    private func syncLayers() {
        do {
            if player == nil {
                player = PianoPlayer()
                player?.soundingNotesHandler = { [weak self] notes in
                    MainActor.assumeIsolated { self?.sounding = notes }
                }
                try player?.start()
                applyFX()
            }
            guard let player else { return }
            let wanted = Set(selected.map(\.url))
            let have = Set(player.layerIDs)
            for url in wanted.subtracting(have) {
                let data = try Data(contentsOf: url)
                if url.pathExtension.lowercased() == "npno" {
                    try player.addLayer(bytes: [UInt8](data), id: url, gain: gains[url] ?? 1)
                } else {
                    try player.addSampleLayer(bytes: [UInt8](data), id: url, gain: gains[url] ?? 1)
                }
            }
            for url in have.subtracting(wanted) { player.removeLayer(id: url) }
            updateHeader()
        } catch {
            status = "Error: \(error)"
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
        let kind = first.url.pathExtension.lowercased() == "npno" ? "piano" : "sample"
        status = selected.count > 1
            ? "Layering \(selected.count) sounds — \(info.zones) zones in \(first.name)"
            : "Playing \(kind) — \(info.zones) zones. MIDI in, built-in audio out."
    }

    private func applyFX() {
        let cutoff = 200 * pow(90, filterNorm)
        player?.setFilter(enabled: filterOn, cutoffHz: cutoff)
        player?.setCompressor(amount: compOn ? compAmount : 0)
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
            if url.pathExtension.lowercased() == "npno" {
                try player.addLayer(bytes: [UInt8](data), id: url)
            } else {
                try player.addSampleLayer(bytes: [UInt8](data), id: url)
            }
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
            player = try PianoPlayer()
            player?.soundingNotesHandler = { [weak self] notes in
                MainActor.assumeIsolated { self?.sounding = notes }
            }
            try player?.start()
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
