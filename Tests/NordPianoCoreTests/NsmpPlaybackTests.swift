import XCTest
import NordPianoCore
import NordPianoEngine

/// Sample playback wiring: zone → stroke resolution and engine layer handling for a
/// decoded `.nsmp4` fixture (no audio engine started — layer bookkeeping only).
final class NsmpPlaybackTests: XCTestCase {
    private func loadFixture() throws -> [UInt8] {
        let thisFile = URL(fileURLWithPath: #filePath)
        let url = thisFile.deletingLastPathComponent().appendingPathComponent("Fixtures/soft-wave-lead.nsmp4")
        return [UInt8](try Data(contentsOf: url))
    }

    func testZoneToStrokeResolution() throws {
        let bytes = try loadFixture()
        let zones = readNsmpZones(bytes)
        let decoded = try decodeNsmpStrokes(bytes)
        let ids = Set(decoded.map { $0.stroke.globalID })
        // Every zone must name a decodable stroke.
        for zone in zones {
            XCTAssertTrue(ids.contains(UInt32(zone.globalID)), "zone root \(zone.rootKey) → missing stroke \(zone.globalID)")
        }
        // MIDI 30 (bottom zone, root 30), 48 (root 48), 108 (top zone) resolve to the
        // zone rooted at or below the note; the stroke's sample rate is its pitch base.
        for (note, root) in [(30, 30), (48, 48), (108, 108)] {
            let zone = nsmpZone(for: note, velocity: 80, in: zones)
            XCTAssertEqual(zone?.rootKey, root)
            XCTAssertNotNil(zone)
            XCTAssertTrue(zone!.keyLow <= note && note <= zone!.keyHigh)
            let stroke = decoded.first { Int($0.stroke.globalID) == zone!.globalID }
            XCTAssertNotNil(stroke)
            XCTAssertGreaterThan(stroke!.stroke.sampleRate, 8000)
            XCTAssertNotNil(stroke!.stroke.loop)
        }
        // Key outside every zone plays nothing.
        XCTAssertNil(nsmpZone(for: 109, velocity: 80, in: zones))
        XCTAssertNil(nsmpZone(for: -1, velocity: 80, in: zones))
    }

    func testEngineSampleLayer() throws {
        let bytes = try loadFixture()
        let url = URL(fileURLWithPath: "/tmp/soft-wave-lead.nsmp4")
        let player = PianoPlayer()
        try player.addSampleLayer(bytes: bytes, id: url)
        XCTAssertEqual(player.layerIDs, [url])
        // Markers are the zone root keys, absolute (no piano +4 offset).
        XCTAssertEqual(player.markers.sorted(), [30, 36, 40, 44, 48, 52, 56, 60, 64, 68, 72,
                                                 76, 80, 84, 88, 92, 96, 100, 104, 108])
        player.removeLayer(id: url)
        XCTAssertTrue(player.layerIDs.isEmpty)
        // Pianos still load through the same player.
        var piano = [UInt8](repeating: 0, count: 0x100)
        piano[0] = 0x43; piano[1] = 0x42; piano[2] = 0x49; piano[3] = 0x4e
        XCTAssertThrowsError(try player.addLayer(bytes: piano, id: URL(fileURLWithPath: "/tmp/x.npno")))
    }
}
