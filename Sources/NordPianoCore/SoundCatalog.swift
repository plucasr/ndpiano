import Foundation

/// Engine box a sound belongs to (the Nord Stage panel sections).
public enum SoundCategory: String, Codable, CaseIterable {
    case piano, organ, synth, moog, orchestral, other
}

/// Sub-navigation inside the Piano engine (GRAND / UPRIGHT / EP / CLAV buttons).
public enum PianoSubcategory: String, Codable, CaseIterable {
    case grand, upright, ep, clav
}

/// Sub-navigation inside the Organ engine (B3 / HAMMOND / FARF / PIPE).
public enum OrganSubcategory: String, Codable, CaseIterable {
    case b3, hammond, farfisa, pipe
}

/// Sub-navigation inside the Synth engine (BASS / PAD / LEAD / STRINGS / ARP / FX).
public enum SynthSubcategory: String, Codable, CaseIterable {
    case bass, pad, lead, strings, arp, fx
}

/// Sub-navigation inside the Orchestral engine (STRINGS / BRASS / WOODWINDS /
/// MALLETS / CHOIR) — the Nord Sample Library's acoustic sections.
public enum OrchestralSubcategory: String, Codable, CaseIterable {
    case strings, brass, woodwinds, mallets, choir
}

/// One imported sound: identity comes from the file header at import time, the
/// rest is user data. `id` is stable — scenes and channels reference it, never
/// the path, so moving the managed library doesn't break anything.
public struct CatalogEntry: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var name: String
    public var version: String
    public var category: SoundCategory
    /// Raw value of the category's subcategory enum (e.g. "grand", "b3", "pad").
    /// A plain string so old catalogs decode no matter which enums exist.
    public var subcategory: String?
    /// Absolute path — inside the managed library (copied) or the original
    /// location (imported by reference).
    public var path: String
    public var dateAdded: Date
    /// File size at import time (panel headers show totals).
    public var sizeBytes: Int64 = 0
    public init(id: UUID = UUID(), name: String, version: String, category: SoundCategory,
                subcategory: String?, path: String, dateAdded: Date = Date(), sizeBytes: Int64 = 0) {
        self.id = id
        self.name = name
        self.version = version
        self.category = category
        self.subcategory = subcategory
        self.path = path
        self.dateAdded = dateAdded
        self.sizeBytes = sizeBytes
    }

    public var pianoSubcategory: PianoSubcategory? { subcategory.flatMap(PianoSubcategory.init) }
    public var organSubcategory: OrganSubcategory? { subcategory.flatMap(OrganSubcategory.init) }
    public var synthSubcategory: SynthSubcategory? { subcategory.flatMap(SynthSubcategory.init) }
    public var orchestralSubcategory: OrchestralSubcategory? { subcategory.flatMap(OrchestralSubcategory.init) }
}

/// Name-based classification. Neither file format carries an instrument-type
/// field, but Nord's library naming is consistent ("EP7 Amped Tines", "Felt
/// Upright", "Grand Imperial"), so a keyword pass gets most imports right;
/// anything ambiguous falls back to a manual pick.
public enum SoundClassifier {

    /// Piano subcategory from a sound name; nil = unknown (user picks).
    public static func pianoSubcategory(name: String) -> PianoSubcategory? {
        let n = name.lowercased()
        // Clav/harpsichord first: "Clavinet D6" also matches the EP keywords.
        if n.contains("clavinet") || n.range(of: #"\bclav\b"#, options: .regularExpression) != nil
            || n.contains("harpsi") || n.contains("cembalo") || n.contains("d6") {
            return .clav
        }
        if n.range(of: #"\bep\d"#, options: .regularExpression) != nil || n.contains("epiano")
            || n.contains("rhodes") || n.contains("wurlitzer") || n.contains("wurli")
            || n.range(of: #"\bdx\d"#, options: .regularExpression) != nil || n.contains("cp80") || n.contains("cp-80") {
            return .ep
        }
        if n.contains("upright") || n.contains("honktonk") || n.contains("honky") { return .upright }
        if n.contains("grand") || n.contains("imperial") || n.contains("concert")
            || n.contains("steinway") || n.contains("bechstein") || n.contains("acoustic piano")
            || n.range(of: #"\bcfx\b"#, options: .regularExpression) != nil || n.contains("bösendorfer") || n.contains("bosendorfer") {
            return .grand
        }
        // Anything else self-describing as a piano (Toy Piano, RainPiano, M1 piano…).
        if n.contains("piano") { return .grand }
        return nil
    }

    /// Organ subcategory from a sound name; nil = unknown.
    public static func organSubcategory(name: String) -> OrganSubcategory? {
        let n = name.lowercased()
        // Hammond-named sets (HamOrg, drawbar/tone programs) before the B3
        // pattern: a "Hammond B3" name should land in hammond.
        if n.contains("hammond") || n.contains("hamorg") || n.contains("tonewheel")
            || n.contains("tone wheel") || n.contains("drawbar") {
            return .hammond
        }
        if n.contains("pipe") || n.contains("principal") || n.contains("cathedral")
            || n.contains("church") || n.contains("gamba") || n.contains("organ flute")
            || n.contains("flojt") {
            return .pipe
        }
        if n.contains("farfisa") || n.contains("vox") || n.contains("continental")
            || n.contains("combo") {
            return .farfisa
        }
        if n.range(of: #"\bb-?3\b"#, options: .regularExpression) != nil
            || n.range(of: #"\bc-?3\b"#, options: .regularExpression) != nil
            || n.range(of: #"\ba-?100\b"#, options: .regularExpression) != nil {
            return .b3
        }
        return nil
    }

    /// Synth subcategory from a sound name; nil = unknown.
    public static func synthSubcategory(name: String) -> SynthSubcategory? {
        let n = name.lowercased()
        if n.contains("bass") || n.range(of: #"\bsub\b"#, options: .regularExpression) != nil { return .bass }
        if n.contains("arp") || n.range(of: #"\bseq"#, options: .regularExpression) != nil { return .arp }
        if n.contains("pad") || n.contains("ambient") || n.contains("crystal")
            || n.contains("drone") || n.contains("atmo")
            || n.contains("choir") || n.contains("vocal") || n.range(of: #"\baah\b"#, options: .regularExpression) != nil {
            return .pad
        }
        // String-machine naming: "Eminent 310 Str L 8", "AnaStrings", "Symphony".
        if n.contains("string") || n.contains("strung")
            || n.range(of: #"\bstr"#, options: .regularExpression) != nil
            || n.contains("symphony") || n.contains("rhapsod")
            || n.contains("combi") || n.contains("trident") || n.contains("lambda")
            || n.contains("violin") || n.contains("viola") || n.contains("cello") {
            return .strings
        }
        if n.contains("fx") || n.contains("sweep") || n.contains("riser")
            || n.contains("noise") || n.contains("effect") {
            return .fx
        }
        if n.contains("lead") || n.contains("solo") { return .lead }
        return nil
    }

    /// Orchestral subcategory from a sound name; nil = unknown.
    public static func orchestralSubcategory(name: String) -> OrchestralSubcategory? {
        let n = name.lowercased()
        if n.contains("marimba") || n.contains("vibra") || n.contains("vibes") || n.contains("glocken")
            || n.contains("xylophone") || n.contains("celest") || n.contains("kalimba")
            || n.contains("bells") || n.contains("steel drum") || n.contains("tubular")
            || n.contains("crotales") || n.contains("mbira") || n.contains("metallophone")
            || n.contains("chimes") || n.contains("gong") || n.contains("himalayan")
            || n.contains("belltower") {
            return .mallets
        }
        if n.contains("choir") || n.contains("vocal") || n.range(of: #"\bvoice"#, options: .regularExpression) != nil
            || n.range(of: #"\baah\b"#, options: .regularExpression) != nil || n.range(of: #"\booh\b"#, options: .regularExpression) != nil {
            return .choir
        }
        // Woodwinds before brass: an "English Horn" is a woodwind.
        if n.contains("english horn") || n.contains("flute") || n.contains("clarinet")
            || n.contains("oboe") || n.contains("bassoon") || n.contains("sax")
            || n.contains("woodwind") || n.contains("recorder") || n.contains("piccolo")
            || n.contains("wind") || n.contains("bagpipe") || n.contains("panpipe")
            || n.contains("whistle") || n.contains("bansuri") || n.contains("shakuhachi")
            || n.contains("suona") || n.contains("shehnai") {
            return .woodwinds
        }
        if n.contains("brass") || n.contains("trumpet") || n.contains("trombone")
            || n.contains("tuba") || n.range(of: #"\bhorn"#, options: .regularExpression) != nil
            || n.contains("alphorn") || n.contains("cornet") || n.contains("flugel")
            || n.contains("supreme") || n.contains("big band") {
            return .brass
        }
        if n.contains("string") || n.contains("viol") || n.contains("cell")
            || n.contains("contrabass") || n.contains("basses") || n.contains("orchestra")
            || n.contains("chamber") || n.contains("ensemble") || n.contains("pizzicato")
            || n.contains("symphstr") || n.contains("swingstr") || n.contains("strquint")
            || n.contains("harpa") || n.contains("nyckel") {
            return .strings
        }
        return nil
    }

    /// Category from extension + name + the folder the file was imported from.
    /// Folder names are the strongest hint: Nord distributes its samples in
    /// folders like "Strings - Nord Wave 2" or "Synth - Nord Electro 7", so
    /// those decide first; name keywords break ties for loose files.
    public static func category(ext: String, name: String, sourceFolder: String = "") -> SoundCategory {
        if ext == "npno" { return .piano }
        if ext == "moog" { return .moog }
        let folder = sourceFolder.lowercased()
        if folder.contains("synth") { return .synth }
        if folder.contains("organ") { return .organ }
        if folder.contains("piano") || folder.contains("keyboard") { return .piano }
        if folder.contains("strings analog") { return .synth }
        if folder.contains("string") || folder.contains("brass") || folder.contains("woodwind")
            || folder.contains("percussion") || folder.contains("choir") || folder.contains("orchestr") {
            return .orchestral
        }
        let n = name.lowercased()
        if n.contains("organ") || n.contains("b3") || n.contains("hammond")
            || n.contains("farfisa") || n.contains("vox continental") {
            return .organ
        }
        // Acoustic instruments before synth keywords: an "Analog Brass" from a
        // loose folder is still a synth patch, but a bare "Trumpet" is orchestral.
        if orchestralSubcategory(name: name) != nil, !n.contains("analog"), !n.contains("syn") {
            return .orchestral
        }
        if n.contains("synth") || n.contains("lead") || n.contains("pad")
            || n.contains("wave") || n.contains("arp") || n.contains("bass") {
            return .synth
        }
        // SoundFonts with no other hint land in the synth engine (the format is
        // overwhelmingly used for synth and GM banks).
        if ext == "sf2" { return .synth }
        return .other
    }
}

public enum CatalogError: Error, Equatable {
    case unreadableFile(String)
    case unsupportedType(String)
}

/// The app-managed sound library: a JSON catalog plus the imported files under
/// `Library/<Category>/<file>`. Pure data + file copies — no audio, fully
/// unit-testable.
public struct SoundCatalog: Codable {
    public var entries: [CatalogEntry] = []

    public init() {}

    // MARK: - Locations

    /// ~/Library/Application Support/nordpiano
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nordpiano", isDirectory: true)
    }

    public static var defaultCatalogURL: URL {
        supportDirectory.appendingPathComponent("catalog.json")
    }

    /// Root of the managed library (imported file copies live here by category).
    public static var defaultLibraryRoot: URL {
        supportDirectory.appendingPathComponent("Library", isDirectory: true)
    }

    // MARK: - Persistence

    public static func load(from url: URL = defaultCatalogURL) -> SoundCatalog {
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(SoundCatalog.self, from: data) else {
            return SoundCatalog()
        }
        return catalog
    }

    public func save(to url: URL = defaultCatalogURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Import

    /// Import a sound file: read its identity from the header, classify it (with
    /// optional user overrides), copy it into the managed library (or reference
    /// it in place), and register it. Re-importing the same path updates the
    /// existing entry instead of duplicating it.
    @discardableResult
    public mutating func importFile(at source: URL,
                                    category: SoundCategory? = nil,
                                    subcategory: String? = nil,
                                    copy: Bool = true,
                                    libraryRoot: URL = defaultLibraryRoot) throws -> CatalogEntry {
        let ext = source.pathExtension.lowercased()
        guard ["npno", "nsmp3", "nsmp4", "sfz", "sf2", "moog"].contains(ext) else {
            throw CatalogError.unsupportedType(ext)
        }
        // SFZ programs reference their samples by relative path — copying just
        // the .sfz into the managed library would orphan them, so SFZ imports
        // are always by reference (the source folder must stay in place).
        let copy = copy && ext != "sfz"
        guard let (name, version) = SoundCatalog.identity(of: source) else {
            throw CatalogError.unreadableFile(source.lastPathComponent)
        }
        let resolvedCategory = category
            ?? SoundClassifier.category(ext: ext, name: name,
                                        sourceFolder: source.deletingLastPathComponent().lastPathComponent)
        let heuristic: String? = switch resolvedCategory {
        case .piano: SoundClassifier.pianoSubcategory(name: name)?.rawValue
        case .organ: SoundClassifier.organSubcategory(name: name)?.rawValue
        case .synth: SoundClassifier.synthSubcategory(name: name)?.rawValue
        case .orchestral: SoundClassifier.orchestralSubcategory(name: name)?.rawValue
        case .moog, .other: nil
        }
        let resolvedSubcategory = subcategory ?? heuristic
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0

        var destination = source
        if copy {
            let dir = libraryRoot.appendingPathComponent(resolvedCategory.rawValue.capitalized, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            destination = uniqueDestination(in: dir, fileName: source.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }

        let entry = CatalogEntry(name: name, version: version, category: resolvedCategory,
                                 subcategory: resolvedSubcategory, path: destination.path,
                                 sizeBytes: size)
        if let i = entries.firstIndex(where: { $0.path == source.path && copy == false }) {
            entries[i] = entry // re-import by reference: refresh identity/category
        } else if let i = entries.firstIndex(where: { $0.name == name && $0.path == destination.path }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        return entry
    }

    public mutating func remove(_ entry: CatalogEntry, deleteFile: Bool = false) {
        entries.removeAll { $0.id == entry.id }
        if deleteFile { try? FileManager.default.removeItem(atPath: entry.path) }
    }

    public mutating func recategorize(_ entry: CatalogEntry, to category: SoundCategory,
                                      subcategory: String? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].category = category
        entries[i].subcategory = subcategory
    }

    public func entries(in category: SoundCategory, subcategory: String? = nil) -> [CatalogEntry] {
        entries
            .filter { $0.category == category && (subcategory == nil || $0.subcategory == subcategory) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Helpers

    /// Header read: name + version without decoding audio (pianos are tens of MB).
    public static func identity(of url: URL) -> (name: String, version: String)? {
        let ext = url.pathExtension.lowercased()
        let fallback = url.deletingPathExtension().lastPathComponent
        if ext == "moog" {
            // JSON patch; the display name comes from the file's "name" key
            // (bare patch files fall back to the filename).
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["patch"] is [String: Any] || obj["cutoffHz"] != nil else { return nil }
            return ((obj["name"] as? String) ?? fallback, "")
        }
        if ext == "sfz" {
            guard !SfzParser.parseFile(url).regions.isEmpty else { return nil }
            return (fallback, "")
        }
        if ext == "sf2" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 12)) ?? Data()
            guard isSoundFont(bytes: [UInt8](head)) else { return nil }
            return (fallback, "")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2048), head.count > 0x67 else { return nil }
        let bytes = [UInt8](head)
        if ext == "npno" {
            guard let id = readNspIdentity(bytes) else { return nil }
            return (id.name ?? fallback, id.version)
        }
        let id = identifyNsmp(bytes)
        guard id.recognized, !id.legacy else { return nil }
        return (readNsmpName(bytes) ?? fallback, id.version ?? "")
    }

    /// Non-colliding destination: "Name.ext", "Name 2.ext", …
    private func uniqueDestination(in dir: URL, fileName: String) -> URL {
        let fm = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = dir.appendingPathComponent(fileName)
        var n = 2
        // An existing file with the same name is fine if it IS the same import
        // (re-import of a file already in the library) — caller decides via entries.
        while fm.fileExists(atPath: candidate.path)
                && !entries.contains(where: { $0.path == candidate.path }) {
            candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
