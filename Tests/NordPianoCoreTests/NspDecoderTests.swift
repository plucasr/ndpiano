import XCTest
@testable import NordPianoCore

final class NspDecoderTests: XCTestCase {
    func testFindCnsp() {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x2c] = 0x43; bytes[0x2d] = 0x4e; bytes[0x2e] = 0x53; bytes[0x2f] = 0x50
        XCTAssertEqual(findCnsp(bytes), 0x2c)
        XCTAssertNil(findCnsp([UInt8](repeating: 0, count: 0x100)))
    }

    func testTouchAttenuationBounds() {
        XCTAssertEqual(touchAttenuation(127), 0, accuracy: 1e-9)
        XCTAssertEqual(touchAttenuation(0), touchAttenuation(1))
        XCTAssertLessThanOrEqual(touchAttenuation(1), 200)
        XCTAssertEqual(touchAttenuation(200), 0, accuracy: 1e-9)
    }

    func testPianoKey() {
        let zones = [NspZone(rootNote: 21, lowNote: 0, highNote: 40), NspZone(rootNote: 48, lowNote: 41, highNote: 127)]
        XCTAssertNil(pianoKey(zones, midi: -1) as Any?)
        let hit = pianoKey(zones, midi: 48)
        XCTAssertEqual(hit!.zone, 1)
        XCTAssertEqual(hit!.semitones, 48 - 48 - 4, accuracy: 1e-9)
        let low = pianoKey(zones, midi: 30)
        XCTAssertEqual(low!.zone, 0)
        XCTAssertEqual(low!.semitones, 30 - 21 - 4, accuracy: 1e-9)
    }
}
