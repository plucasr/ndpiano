import XCTest
@testable import NordPianoEngine

final class NsmpBridgeTests: XCTestCase {
    func testDecodeSyntheticSample() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let bytes = [UInt8](try Data(contentsOf: dir.appendingPathComponent("sample.nsmp")))
        let expected = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("sample-expected.json"))) as! [String: Any]

        let file = try NsmpBridge.shared.load(bytes: bytes)
        XCTAssertEqual(file.zones.count, expected["zoneCount"] as! Int)
        XCTAssertEqual(file.zones.first?.globalID, expected["globalID"] as? Int)
        NsmpBridge.shared.release(handle: file.handle)

        let reload = try NsmpBridge.shared.load(bytes: bytes)
        let stroke = try NsmpBridge.shared.decodeStroke(handle: reload.handle, globalID: expected["globalID"] as! Int)
        XCTAssertEqual(stroke.channels.count, 1)
        XCTAssertEqual(stroke.channels[0].count, expected["frames"] as! Int)
        XCTAssertEqual(stroke.sampleRate, expected["sampleRate"] as! Double, accuracy: 0.5)
        // Decoded PCM peak matches the TS decoder (before engine-side normalization).
        let peak = stroke.channels[0].map(abs).max()!
        XCTAssertEqual(Double(peak), expected["peak"] as! Double, accuracy: 1.5)
        NsmpBridge.shared.release(handle: reload.handle)
    }
}
