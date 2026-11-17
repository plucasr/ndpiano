import XCTest
@testable import NordPianoCore

final class SoundCatalogTests: XCTestCase {

    // MARK: - Classifier

    func testPianoSubcategoryEP() {
        for name in ["EP7 Amped Tines", "EP9 Stockholm", "Wurlitzer 2", "Rhodes Mk II",
                     "DX7 Full Tines", "CP80 Electric Grand"] {
            XCTAssertEqual(SoundClassifier.pianoSubcategory(name: name), .ep, name)
        }
        for name in ["Clavinet D6", "Harpsichord 8ft"] {
            XCTAssertEqual(SoundClassifier.pianoSubcategory(name: name), .clav, name)
        }
    }

    func testPianoSubcategoryGrandAndUpright() {
        for name in ["Grand Imperial", "Royal Grand 3D", "Soft Grand", "Studio Grand CFX"] {
            XCTAssertEqual(SoundClassifier.pianoSubcategory(name: name), .grand, name)
        }
        for name in ["Felt Upright", "Pearl Upright"] {
            XCTAssertEqual(SoundClassifier.pianoSubcategory(name: name), .upright, name)
        }
    }

    func testPianoSubcategoryUnknown() {
        XCTAssertNil(SoundClassifier.pianoSubcategory(name: "Blue Swede"))
    }

    func testCategoryFromExtensionAndHints() {
        XCTAssertEqual(SoundClassifier.category(ext: "npno", name: "Anything"), .piano)
        XCTAssertEqual(SoundClassifier.category(ext: "nsmp4", name: "Cathedral Organ"), .organ)
        XCTAssertEqual(SoundClassifier.category(ext: "nsmp4", name: "Soft Wave Lead"), .synth)
        XCTAssertEqual(SoundClassifier.category(ext: "nsmp4", name: "Mystery",
                                                sourceFolder: "Organ - Nord"), .organ)
        XCTAssertEqual(SoundClassifier.category(ext: "nsmp4", name: "Mystery"), .other)
    }

    func testOrganSubcategory() {
        for name in ["B3 Drawbars", "Hammond C3", "HamOrg (Free Version)"] {
            XCTAssertEqual(SoundClassifier.organSubcategory(name: name), .hammond, name)
        }
        for name in ["B3 Model", "C3 Split"] {
            XCTAssertEqual(SoundClassifier.organSubcategory(name: name), .b3, name)
        }
        for name in ["Farfisa Compact", "Vox Continental"] {
            XCTAssertEqual(SoundClassifier.organSubcategory(name: name), .farfisa, name)
        }
        for name in ["Pipe Principal", "Cathedral Organ", "Gamba 8"] {
            XCTAssertEqual(SoundClassifier.organSubcategory(name: name), .pipe, name)
        }
    }

    func testSynthSubcategory() {
        for name in ["101 Bass 1", "Sub Wave"] {
            XCTAssertEqual(SoundClassifier.synthSubcategory(name: name), .bass, name)
        }
        for name in ["Analog Pad Nine", "Crystal Pad"] {
            XCTAssertEqual(SoundClassifier.synthSubcategory(name: name), .pad, name)
        }
        for name in ["Saw Lead X", "Soft Wave Lead"] {
            XCTAssertEqual(SoundClassifier.synthSubcategory(name: name), .lead, name)
        }
        for name in ["AnaStrings DX7", "Arp Sequence One", "Sweep FX"] {
            XCTAssertEqual([SynthSubcategory.strings, .arp, .fx].contains(SoundClassifier.synthSubcategory(name: name)!), true, name)
        }
    }

    func testOrchestralSubcategory() {
        XCTAssertEqual(SoundClassifier.orchestralSubcategory(name: "Solo Violin"), .strings)
        XCTAssertEqual(SoundClassifier.orchestralSubcategory(name: "String Ensemble"), .strings)
        XCTAssertEqual(SoundClassifier.orchestralSubcategory(name: "Trumpet Section"), .brass)
        XCTAssertEqual(SoundClassifier.orchestralSubcategory(name: "Concert Flute"), .woodwinds)
        XCTAssertEqual(SoundClassifier.orchestralSubcategory(name: "Marimba"), .mallets)
        XCTAssertEqual(SoundClassifier.orchestralSubcategory(name: "Choir Aah"), .choir)
    }

    func testCategoryFromFolderHints() {
        XCTAssertEqual(SoundClassifier.category(ext: "nsmp3", name: "Mystery",
                                                sourceFolder: "Strings - Nord Wave 2"), .orchestral)
        XCTAssertEqual(SoundClassifier.category(ext: "nsmp3", name: "Mystery",
                                                sourceFolder: "Strings Analog - Nord Wave 2"), .synth)
        XCTAssertEqual(SoundClassifier.category(ext: "nsmp3", name: "Mystery",
                                                sourceFolder: "Tuned Percussion - Nord Wave 2"), .orchestral)
        XCTAssertEqual(SoundClassifier.category(ext: "nsmp3", name: "Mystery",
                                                sourceFolder: "Piano_Keyboard - Nord Wave 2"), .piano)
        XCTAssertEqual(SoundClassifier.category(ext: "nsmp3", name: "Trumpet"), .orchestral)
        XCTAssertEqual(SoundClassifier.category(ext: "nsmp3", name: "Analog Brass"), .other)
    }

    func testImportClassifiesSubcategoryAndSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = SoundCatalog()
        let entry = try catalog.importFile(at: fixtureURL, libraryRoot: root) // Soft Wave Lead
        XCTAssertEqual(entry.subcategory, SynthSubcategory.lead.rawValue)
        XCTAssertEqual(entry.synthSubcategory, .lead)
        XCTAssertGreaterThan(entry.sizeBytes, 0)
    }

    // MARK: - Persistence round-trip

    func testSaveLoadRoundTrip() throws {
        var catalog = SoundCatalog()
        let entry = CatalogEntry(name: "Grand Imperial", version: "6.10", category: .piano,
                                 subcategory: "grand", path: "/tmp/x/Grand Imperial.npno")
        catalog.entries.append(entry)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("catalog.json")
        try catalog.save(to: url)
        let loaded = SoundCatalog.load(from: url)
        XCTAssertEqual(loaded.entries, [entry])
    }

    func testLoadMissingFileGivesEmptyCatalog() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope/catalog.json")
        XCTAssertTrue(SoundCatalog.load(from: url).entries.isEmpty)
    }

    // MARK: - Import

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/soft-wave-lead.nsmp4")
    }

    func testImportCopiesFileAndRegistersEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var catalog = SoundCatalog()
        let entry = try catalog.importFile(at: fixtureURL, libraryRoot: root)
        XCTAssertEqual(entry.name, "Soft Wave Lead")
        XCTAssertEqual(entry.version, "4.10")
        XCTAssertEqual(entry.category, .synth) // "Lead" heuristic
        XCTAssertTrue(entry.path.hasPrefix(root.appendingPathComponent("Synth").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
        XCTAssertEqual(catalog.entries.count, 1)
    }

    func testImportByReferenceKeepsOriginalPath() throws {
        var catalog = SoundCatalog()
        let entry = try catalog.importFile(at: fixtureURL, copy: false)
        XCTAssertEqual(entry.path, fixtureURL.path)
    }

    func testImportOverridesHeuristics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var catalog = SoundCatalog()
        let entry = try catalog.importFile(at: fixtureURL, category: .organ, libraryRoot: root)
        XCTAssertEqual(entry.category, .organ)
        XCTAssertTrue(entry.path.contains("/Organ/"))
    }

    func testImportRejectsUnsupportedAndGarbage() throws {
        var catalog = SoundCatalog()
        let txt = FileManager.default.temporaryDirectory.appendingPathComponent("note.txt")
        try "hi".write(to: txt, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try catalog.importFile(at: txt)) {
            XCTAssertEqual($0 as? CatalogError, .unsupportedType("txt"))
        }
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad.nsmp4")
        try Data(repeating: 0, count: 4096).write(to: bad)
        XCTAssertThrowsError(try catalog.importFile(at: bad)) {
            XCTAssertEqual($0 as? CatalogError, .unreadableFile("bad.nsmp4"))
        }
    }

    func testEntriesFilteringAndRecategorize() throws {
        var catalog = SoundCatalog()
        catalog.entries = [
            CatalogEntry(name: "B Grand", version: "", category: .piano, subcategory: "grand", path: "/b"),
            CatalogEntry(name: "A EP", version: "", category: .piano, subcategory: "ep", path: "/a"),
            CatalogEntry(name: "C Organ", version: "", category: .organ, subcategory: nil, path: "/c"),
        ]
        XCTAssertEqual(catalog.entries(in: .piano).map(\.name), ["A EP", "B Grand"])
        XCTAssertEqual(catalog.entries(in: .piano, subcategory: "ep").map(\.name), ["A EP"])

        let ep = catalog.entries[1]
        catalog.recategorize(ep, to: .organ)
        XCTAssertEqual(catalog.entries[1].category, .organ)
        XCTAssertNil(catalog.entries[1].subcategory)
    }
}
