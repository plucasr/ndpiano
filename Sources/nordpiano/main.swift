import Foundation
import NordPianoCore
import NordPianoEngine

setbuf(stdout, nil) // print() through a pipe is block-buffered otherwise

// Local-only Nord Piano (.npno) player:
//   nordpiano info <file.npno>   — print zones, strokes, loops
//   nordpiano play <file.npno>   — MIDI in (CoreMIDI), audio out (CoreAudio); Ctrl-C to quit
//   nordpiano import <folder>… [--reference] [--dry-run]
//                               — bulk-import .npno/.nsmp3/.nsmp4 into the app
//                                 catalog (copied into the managed library;
//                                 --reference keeps files in place), classifying
//                                 by folder + name. --dry-run only reports.
let args = CommandLine.arguments
guard args.count > 1 else {
    fputs("usage: nordpiano info|play|demo <file.npno> | import <folder>… [--reference] [--dry-run]\n", stderr)
    exit(2)
}

// nordpiano check <folder>… — validate every sound file the way the player
// would: identity, zone table, and a full stroke decode (catches files that
// import fine but stay silent). Prints OK/FAIL per file plus a summary.
if args[1] == "check" {
    let verbose = args.contains("--verbose")
    let roots = args.dropFirst(2).filter { !$0.hasPrefix("--") }
    guard !roots.isEmpty else {
        fputs("usage: nordpiano check <folder>…\n", stderr)
        exit(2)
    }

    /// Failures with a human-readable reason; nil = the file plays.
    func diagnose(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "sfz" {
            let program = SfzParser.parseFile(url)
            guard !program.regions.isEmpty else { return "no regions" }
            let dir = url.deletingLastPathComponent()
            let missing = program.regions.filter {
                !FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent($0.sample.replacingOccurrences(of: "\\", with: "/")).path)
            }
            return missing.isEmpty ? nil : "\(missing.count)/\(program.regions.count) sample files missing"
        }
        if ext == "sf2" {
            let head = (try? FileHandle(forReadingFrom: url).read(upToCount: 12)) ?? Data()
            return isSoundFont(bytes: [UInt8](head)) ? nil : "not an sfbk/DLS container"
        }
        guard let bytes = try? [UInt8](Data(contentsOf: url)) else { return "can't read file" }
        if ext == "npno" {
            guard let dir = try? readNspDirectory(bytes) else { return "no directory" }
            guard !readNspZones(bytes).isEmpty else { return "no zones" }
            var peak: Int32 = 0
            for stroke in dir.strokes {
                let pcm = (try? decodeNspStroke(bytes, dir: dir, stroke: stroke)) ?? []
                for ch in pcm { for s in ch { peak = max(peak, abs(Int32(s))) } }
            }
            guard peak > 0 else { return "decodes to silence" }
            return nil
        }
        let id = identifyNsmp(bytes)
        guard id.recognized else { return "not an nsmp3/4" }
        guard !id.legacy, let codec = id.codec, codec == 3 || codec == 4 else {
            return "legacy nsmp (codec \(id.codec.map(String.init) ?? "?")) — unsupported"
        }
        let zones = readNsmpZones(bytes)
        guard !zones.isEmpty else { return "no zones" }
        if verbose {
            print("  \(url.lastPathComponent) — \(zones.count) zones:")
            for z in zones {
                print("    keys \(z.keyLow)…\(z.keyHigh)  vel \(z.velLow)…\(z.velTop)  root \(z.rootKey)  gid \(z.globalID)  playback \(z.zonePlayback)")
            }
        }
        guard let strokes = try? decodeNsmpStrokes(bytes), !strokes.isEmpty else { return "stroke decode failed" }
        var peak: Int32 = 0
        for s in strokes { for ch in s.channels { for v in ch { peak = max(peak, abs(Int32(v))) } } }
        guard peak > 0 else { return "decodes to silence" }
        return nil
    }

    var ok = 0
    var broken: [(String, String)] = []
    for rootArg in roots {
        let root = URL(fileURLWithPath: rootArg)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { fputs("can't open \(rootArg)\n", stderr); continue }
        for case let file as URL in enumerator
        where ["npno", "nsmp3", "nsmp4", "sfz", "sf2"].contains(file.pathExtension.lowercased()) {
            if let reason = diagnose(file) {
                broken.append((file.path, reason))
                print("FAIL  \(file.lastPathComponent) — \(reason)")
            } else {
                ok += 1
            }
        }
    }
    print("\nchecked \(ok + broken.count): \(ok) OK, \(broken.count) broken")
    exit(broken.isEmpty ? 0 : 1)
}

if args[1] == "import" {
    let copy = !args.contains("--reference")
    let dryRun = args.contains("--dry-run")
    let roots = args.dropFirst(2).filter { !$0.hasPrefix("--") }
    guard !roots.isEmpty else {
        fputs("usage: nordpiano import <folder>… [--reference] [--dry-run]\n", stderr)
        exit(2)
    }

    var catalog = SoundCatalog.load()
    var imported = 0, skipped = 0
    var review: [String] = [] // files needing a manual look
    var counts: [String: Int] = [:]

    for rootArg in roots {
        let root = URL(fileURLWithPath: rootArg)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { fputs("can't open \(rootArg)\n", stderr); continue }
        for case let file as URL in enumerator {
            let ext = file.pathExtension.lowercased()
            guard ["npno", "nsmp3", "nsmp4", "sfz"].contains(ext) else { continue }
            let folder = file.deletingLastPathComponent().lastPathComponent
            do {
                if dryRun {
                    guard let (name, _) = SoundCatalog.identity(of: file) else {
                        fputs("UNREADABLE  \(file.lastPathComponent)\n", stderr)
                        skipped += 1
                        continue
                    }
                    let cat = SoundClassifier.category(ext: ext, name: name, sourceFolder: folder)
                    let sub: String? = switch cat {
                    case .piano: SoundClassifier.pianoSubcategory(name: name)?.rawValue
                    case .organ: SoundClassifier.organSubcategory(name: name)?.rawValue
                    case .synth: SoundClassifier.synthSubcategory(name: name)?.rawValue
                    case .orchestral: SoundClassifier.orchestralSubcategory(name: name)?.rawValue
                    case .other: nil
                    }
                    print("\(cat.rawValue)/\(sub ?? "?")  \(name)")
                    if sub == nil { review.append("\(name)  <\(folder)>") }
                    counts[cat.rawValue, default: 0] += 1
                    imported += 1
                } else {
                    let entry = try catalog.importFile(at: file, copy: copy)
                    print("\(entry.category.rawValue)/\(entry.subcategory ?? "?")  \(entry.name)")
                    if entry.subcategory == nil {
                        review.append("\(entry.name)  <\(folder)>  [\(entry.category.rawValue)]")
                    }
                    counts[entry.category.rawValue, default: 0] += 1
                    imported += 1
                }
            } catch {
                fputs("FAILED  \(file.lastPathComponent): \(error.localizedDescription)\n", stderr)
                skipped += 1
            }
        }
    }

    if !dryRun {
        do { try catalog.save() } catch {
            fputs("catalog save failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    print("\n\(dryRun ? "DRY RUN — nothing written" : "Saved to \(SoundCatalog.defaultCatalogURL.path)")")
    print("imported: \(imported)  skipped/failed: \(skipped)")
    for (cat, n) in counts.sorted(by: { $0.key < $1.key }) { print("  \(cat): \(n)") }
    if !review.isEmpty {
        print("\nneeds manual review (\(review.count)):")
        for r in review { print("  \(r)") }
    }
    exit(0)
}

guard args.count > 2 else {
    fputs("usage: nordpiano info|play|demo <file.npno> | import <folder>… [--reference] [--dry-run]\n", stderr)
    exit(2)
}
let url = URL(fileURLWithPath: args[2])
guard let data = try? Data(contentsOf: url) else {
    fputs("can't read \(args[2])\n", stderr)
    exit(1)
}
let bytes = [UInt8](data)

switch args[1] {
case "info":
    let zones = readNspZones(bytes)
    print("zones: \(zones.count)")
    for z in zones { print("  root \(z.rootNote)  keys \(z.lowNote)...\(z.highNote)") }
    do {
        let dir = try readNspDirectory(bytes)
        print("directory: version \(dir.version), \(dir.channels)ch, blockWords \(dir.blockWords), \(dir.strokes.count) strokes, \(nspZoneCount(dir)) key zones")
        for s in dir.strokes {
            print("  stroke \(s.index): zone \(s.zone) floor \(s.velocityFrom) frames \(s.frames) blocks \(s.blocks)" +
                  (s.loop.map { " loop \($0.start)+\($0.length)" } ?? "") + (s.release ? " release" : ""))
        }
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
case "demo":
    do {
        let player = try PianoPlayer(bytes: bytes)
        player.soundingNotesHandler = { notes in print("sounding: \(notes.sorted())") }
        try player.start()
        // Middle-C major scale, one note per second, to verify decode + render + output.
        let seq = [60, 62, 64, 65, 67, 69, 71, 72]
        for (i, n) in seq.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) + 1) {
                print("noteOn \(n)")
                player.noteOn(n, velocity: 100)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { player.noteOff(n) }
            }
        }
        RunLoop.current.run()
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
case "play":
    do {
        let player = try PianoPlayer(bytes: bytes)
        try player.start()
        RunLoop.current.run() // Ctrl-C to quit
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
default:
    fputs("usage: nordpiano info|play <file.npno>\n", stderr)
    exit(2)
}
