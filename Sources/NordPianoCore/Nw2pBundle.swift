import Foundation

public enum BundleError: Error {
    case unzipFailed
    case noMeta
}

/// One program of a `.nw2pbundle`: its display name and the samples it layers
/// (paths relative to the bundle root, from meta.xml's dep list). Programs
/// with an empty list are pure synth patches — no sample content to import.
public struct BundleProgram {
    public let name: String
    /// Bundle-relative path of the `.nw2p` file ("Program/Bank O/X.nw2p").
    public let file: String
    public let samples: [String]
}

/// A `.nw2pbundle` extracted to a temp directory: the parsed program→sample
/// map plus the folder the ZIP was unpacked into (caller deletes it).
public struct ExtractedBundle {
    public let directory: URL
    public let programs: [BundleProgram]
}

/// Resolve each slot's numeric sample id (oscWave) to a bundle-relative sample
/// path. Ground truth: programs with exactly one sample slot and one dep.
/// Remaining programs pair unresolved sample slots (slot order) with
/// unresolved deps (meta.xml order) — dep order follows slot order.
public func resolveNw2SampleIDs(
    programs: [BundleProgram],
    sampleSlots: [String: [(slot: String, wave: Int)]]
) -> [Int: String] {
    var waveToSample: [Int: String] = [:]
    for program in programs {
        let slots = sampleSlots[program.name] ?? []
        if slots.count == 1, program.samples.count == 1 {
            waveToSample[slots[0].wave] = program.samples[0]
        }
    }
    for program in programs {
        let unresolved = (sampleSlots[program.name] ?? []).filter { waveToSample[$0.wave] == nil }
        let freeDeps = program.samples.filter { !waveToSample.values.contains($0) }
        for (slot, dep) in zip(unresolved, freeDeps) {
            waveToSample[slot.wave] = dep
        }
    }
    return waveToSample
}

/// Unpack a `.nw2pbundle` (a ZIP of `Program/*.nw2p`, `Samp Lib/**.nsmp3` and
/// `meta.xml`) and parse the meta. Program binaries themselves aren't decoded —
/// the meta carries each program's sample dependencies, which is what a scene
/// needs. Uses /usr/bin/ditto (Foundation has no ZIP reader).
public func extractNw2pBundle(_ url: URL) throws -> ExtractedBundle {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("nw2pbundle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", url.path, dir.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw BundleError.unzipFailed }
    let metaURL = dir.appendingPathComponent("meta.xml")
    guard let data = FileManager.default.contents(atPath: metaURL.path),
          let programs = parseBundleMeta(data) else {
        throw BundleError.noMeta
    }
    return ExtractedBundle(directory: dir, programs: programs)
}

/// Parse meta.xml: `<file name="Program/Bank O/X.nw2p" depCnt="2" dep0="…" dep1="…"/>`.
private func parseBundleMeta(_ data: Data) -> [BundleProgram]? {
    final class Delegate: NSObject, XMLParserDelegate {
        var programs: [BundleProgram] = []
        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            guard element == "file", let raw = attributes["name"] else { return }
            // "Program/Bank O/Ambient Pno Wh 2.nw2p" → "Ambient Pno Wh 2"
            var name = (raw as NSString).lastPathComponent
            name = (name as NSString).deletingPathExtension
            name = name.replacingOccurrences(of: #"\s+"#, with: " ",
                                             options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let depCount = Int(attributes["depCnt"] ?? "0") ?? 0
            let samples = (0..<depCount).compactMap { attributes["dep\($0)"] }
            programs.append(BundleProgram(name: name, file: raw, samples: samples))
        }
    }
    let delegate = Delegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), !delegate.programs.isEmpty else { return nil }
    return delegate.programs
}
