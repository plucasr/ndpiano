import XCTest
@testable import NordPianoCore

/// Firmware-registry decoders beyond the Wave 2: Electro 6 + Stage 4 layouts,
/// and the MurmurHash2 sound-id used to match a program's referenced sounds.
/// Fixtures are real signature-bank programs (Kevin Powell NE6, Markus
/// Jagerstedt NS4) with values verified against the hardware's own files.
final class FwDecoderTests: XCTestCase {

    private func fixture(_ name: String) -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try! [UInt8](Data(contentsOf: url))
    }

    /// "C-Pop Grand Kp1": Baby Upright piano + LadderBass sample synth.
    func testNe6PianoAndSynthSlots() {
        let p = FwDecoder.decodeNe6(fixture("C-Pop Grand Kp1.ne6p"))
        XCTAssertTrue(p.layoutMatched, "warnings: \(p.warnings)")
        XCTAssertEqual(p.value("piano.enable"), 1)
        XCTAssertEqual(p.value("synth.enable"), 1)
        XCTAssertEqual(p.value("organ.enable"), 0)
        XCTAssertEqual(UInt32(p.value("piano.nameHash") ?? 0),
                       soundId(soundLibraryName(ofFile: "Baby Upright Nordiska  Med 5.4.npno")))
        XCTAssertEqual(UInt32(p.value("synth.smpNameHash") ?? 0),
                       soundId(soundLibraryName(ofFile: "LadderBass_NLA1 mono 3.0.nsmp3")))
    }

    /// "Jeagarn To Go": two piano layers (DX RubbaTines + White Grand),
    /// synth slots empty (sentinel hash).
    func testNs4PianoLayers() {
        let p = FwDecoder.decodeNs4(fixture("Jeagarn To Go.ns4p"))
        XCTAssertTrue(p.layoutMatched, "warnings: \(p.warnings)")
        XCTAssertEqual(p.formatVersion, 309)
        XCTAssertEqual(UInt32(p.value("pianoA.nameHash") ?? 0),
                       soundId(soundLibraryName(ofFile: "DX RubbaTines Lrg 6.0.npno")))
        XCTAssertEqual(UInt32(p.value("pianoB.nameHash") ?? 0),
                       soundId(soundLibraryName(ofFile: "White Grand XL 6.3.npno")))
        XCTAssertEqual(p.value("piano.layerLevelPnoA"), 92)
        XCTAssertEqual(p.value("piano.layerLevelPnoB"), 127)
        XCTAssertEqual(p.value("synthA.smpNameHash"), emptySoundHash)
    }

    /// MurmurHash2 of the library name, verified against hardware-written
    /// programs across three models.
    func testSoundIdVectors() {
        XCTAssertEqual(soundId("Wurlitzer_CL mono 3.1"), 0x728cdded)
        XCTAssertEqual(soundId("Men+Women Mm_SI stereo 3.0"), 0x55c02013)
        XCTAssertEqual(soundId("Bambino Upright Baldwin Med 5.4"), 0x0f907604)
        XCTAssertEqual(soundId("White Grand XL 6.3"), 0x4814254f)
        XCTAssertEqual(soundId(""), 1) // 0 stored as 1
    }

    /// Pianos read underscores as spaces; samples keep them.
    func testSoundLibraryName() {
        XCTAssertEqual(soundLibraryName(ofFile: "White_Grand_XL_6.3.npno"), "White Grand XL 6.3")
        XCTAssertEqual(soundLibraryName(ofFile: "Gamba 8_ST 4.1.nsmp4"), "Gamba 8_ST 4.1")
    }

    func testNe6RejectsGarbage() {
        XCTAssertFalse(FwDecoder.decodeNe6([UInt8](repeating: 0, count: 64)).layoutMatched)
        XCTAssertFalse(FwDecoder.decodeNs4([UInt8](repeating: 0xff, count: 900)).layoutMatched)
    }
}
