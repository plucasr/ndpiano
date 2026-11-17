import XCTest
@testable import NordPianoCore

/// NW2 program decoder + bundle sample-id solver. Fixtures are two real
/// programs from a Nord signature sound bank (Elijah Fox, Wave 2).
final class Nw2DecoderTests: XCTestCase {

    private func fixture(_ name: String) -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try! [UInt8](Data(contentsOf: url))
    }

    func testChoirDecodesWithSampleSlotA() {
        let p = FwDecoder.decodeNw2(fixture("Choir.nw2p"))
        XCTAssertTrue(p.layoutMatched, "warnings: \(p.warnings)")
        XCTAssertEqual(p.formatVersion, 301)
        XCTAssertEqual(p.nw2SlotEnabled("A"), true)
        let src = p.nw2SlotSource("A")
        XCTAssertEqual(src?.isSample, true)
        XCTAssertEqual(src?.wave, 406)
        XCTAssertEqual(p.value("common.slotLevelA"), 91)
    }

    func testAmbientPianoHasThreeSampleSlots() {
        let p = FwDecoder.decodeNw2(fixture("Ambient Pno Wh 2.nw2p"))
        XCTAssertTrue(p.layoutMatched, "warnings: \(p.warnings)")
        for (slot, wave) in [("A", 1303), ("B", 1310), ("C", 1304)] {
            XCTAssertEqual(p.nw2SlotEnabled(slot), true)
            XCTAssertEqual(p.nw2SlotSource(slot)?.isSample, true)
            XCTAssertEqual(p.nw2SlotSource(slot)?.wave, wave)
        }
        XCTAssertEqual(p.nw2SlotEnabled("D"), false)
        XCTAssertEqual(p.value("common.slotLevelA"), 127)
        XCTAssertEqual(p.value("common.slotLevelB"), 48)
    }

    func testRejectsNonProgramData() {
        let p = FwDecoder.decodeNw2([UInt8](repeating: 0, count: 64))
        XCTAssertFalse(p.layoutMatched)
        XCTAssertTrue(p.values.isEmpty)
    }

    /// The solver: singles pin ids directly; multi-slot programs fill in by
    /// slot order once the truth is known.
    func testSampleIDSolver() {
        let programs = [
            BundleProgram(name: "Single", file: "P/s.nw2p", samples: ["Samp Lib/A.nsmp3"]),
            BundleProgram(name: "Layered", file: "P/l.nw2p", samples: ["Samp Lib/A.nsmp3", "Samp Lib/B.nsmp3"]),
        ]
        let slots: [String: [(slot: String, wave: Int)]] = [
            "Single": [("A", 100)],
            "Layered": [("A", 100), ("B", 200)],
        ]
        let map = resolveNw2SampleIDs(programs: programs, sampleSlots: slots)
        XCTAssertEqual(map[100], "Samp Lib/A.nsmp3")
        XCTAssertEqual(map[200], "Samp Lib/B.nsmp3")
    }
}
