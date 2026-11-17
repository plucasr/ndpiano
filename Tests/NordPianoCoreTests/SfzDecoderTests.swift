import XCTest
@testable import NordPianoCore

final class SfzDecoderTests: XCTestCase {

    func testKeyNumbers() {
        XCTAssertEqual(sfzKeyNumber("60"), 60)
        XCTAssertEqual(sfzKeyNumber("c4"), 60)
        XCTAssertEqual(sfzKeyNumber("C4"), 60)
        XCTAssertEqual(sfzKeyNumber("c#4"), 61)
        XCTAssertEqual(sfzKeyNumber("db4"), 61)
        XCTAssertEqual(sfzKeyNumber("a4"), 69)
        XCTAssertEqual(sfzKeyNumber("c-1"), 0)
        XCTAssertNil(sfzKeyNumber("h2"))
        XCTAssertNil(sfzKeyNumber("c"))
    }

    func testBasicRegions() {
        let program = SfzParser.parse("""
            <region> sample=kick.wav key=36
            <region> sample=snare.wav lokey=38 hivel=127 lovel=64 hikey=40
            """)
        XCTAssertEqual(program.regions.count, 2)
        let kick = program.regions[0]
        XCTAssertEqual(kick.sample, "kick.wav")
        XCTAssertEqual(kick.loKey, 36)
        XCTAssertEqual(kick.hiKey, 36)
        XCTAssertEqual(kick.rootKey, 36)
        let snare = program.regions[1]
        XCTAssertEqual(snare.loKey, 38)
        XCTAssertEqual(snare.hiKey, 40)
        XCTAssertEqual(snare.loVel, 64)
        XCTAssertEqual(snare.hiVel, 127)
        XCTAssertEqual(snare.rootKey, 60) // default
    }

    func testGroupAndGlobalInheritance() {
        let program = SfzParser.parse("""
            <global> loop_mode=loop_continuous
            <group> lovel=64 hivel=127 tune=-12
            <region> sample=a.wav key=60
            <region> sample=b.wav key=61 tune=5
            """)
        XCTAssertEqual(program.regions.count, 2)
        for r in program.regions {
            XCTAssertEqual(r.loopMode, .continuous)
            XCTAssertEqual(r.loVel, 64)
        }
        XCTAssertEqual(program.regions[0].tuneCents, -12)
        XCTAssertEqual(program.regions[1].tuneCents, 5) // region overrides group
    }

    func testSamplePathWithSpacesAndDefaultPath() {
        let program = SfzParser.parse("""
            <global> default_path=Hammond Samples
            <region> sample=Drawbar 8 C3.wav lokey=c2 hikey=c3 pitch_keycenter=c3 loop_start=100 loop_end=500
            """)
        XCTAssertEqual(program.regions.count, 1)
        let r = program.regions[0]
        XCTAssertEqual(r.sample, "Hammond Samples/Drawbar 8 C3.wav")
        XCTAssertEqual(r.loKey, 36)
        XCTAssertEqual(r.hiKey, 48)
        XCTAssertEqual(r.rootKey, 48)
        XCTAssertEqual(r.loopStart, 100)
        XCTAssertEqual(r.loopEnd, 500)
    }

    func testCommentsAndReleaseTriggerSkipped() {
        let program = SfzParser.parse("""
            // a comment line
            <region> sample=on.wav key=60 // trailing comment
            <region> sample=off.wav key=60 trigger=release
            """)
        XCTAssertEqual(program.regions.count, 1)
        XCTAssertEqual(program.regions[0].sample, "on.wav")
    }

    func testOneShotMode() {
        let program = SfzParser.parse("<region> sample=a.wav key=60 loop_mode=one_shot")
        XCTAssertTrue(program.regions[0].oneShot)
        XCTAssertEqual(program.regions[0].loopMode, .oneShot)
    }

    func testWavLoopParsing() {
        // Minimal WAV: RIFF/WAVE + smpl chunk with one forward loop 100…499.
        var bytes: [UInt8] = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)
        var smpl = [UInt8](repeating: 0, count: 36) // 9 u32 header fields
        func put32(_ v: Int, into a: inout [UInt8], at i: Int) {
            a[i] = UInt8(v & 0xFF); a[i + 1] = UInt8((v >> 8) & 0xFF)
            a[i + 2] = UInt8((v >> 16) & 0xFF); a[i + 3] = UInt8((v >> 24) & 0xFF)
        }
        put32(1, into: &smpl, at: 28) // one loop
        var loopRec = [UInt8](repeating: 0, count: 24)
        put32(0, into: &loopRec, at: 4) // type: forward
        put32(100, into: &loopRec, at: 8)
        put32(499, into: &loopRec, at: 12)
        let body = smpl + loopRec
        var size = [UInt8](repeating: 0, count: 4)
        put32(body.count, into: &size, at: 0)
        bytes += Array("smpl".utf8) + size + body
        let loop = readWavLoop(bytes)
        XCTAssertEqual(loop?.start, 100)
        XCTAssertEqual(loop?.length, 400)
    }

    func testWavLoopAbsent() {
        let bytes = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)
        XCTAssertNil(readWavLoop(bytes))
        XCTAssertNil(readWavLoop([1, 2, 3]))
    }
}
