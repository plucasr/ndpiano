import XCTest
@testable import NordPianoCore
@testable import NordPianoEngine

/// Slot bookkeeping on PianoPlayer, headless (no engine.start()): add/remove,
/// order, replace-in-place, gain/mute/FX keyed by slot UUID. The audio path
/// itself is covered by listening; these tests pin the refactor's contract.
final class PianoPlayerSlotTests: XCTestCase {

    private var pianoBytes: [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/oracle.npno")
        return try! [UInt8](Data(contentsOf: url))
    }

    private var sampleBytes: [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/soft-wave-lead.nsmp4")
        return try! [UInt8](Data(contentsOf: url))
    }

    func testAddLayerRegistersSlotID() throws {
        let player = PianoPlayer()
        let id = UUID()
        try player.addLayer(bytes: pianoBytes, id: id)
        XCTAssertEqual(player.layerIDs, [id])
    }

    func testLayerOrderFollowsInsertion() throws {
        let player = PianoPlayer()
        let a, b, c: UUID
        (a, b, c) = (UUID(), UUID(), UUID())
        try player.addLayer(bytes: pianoBytes, id: a)
        try player.addSampleLayer(bytes: sampleBytes, id: b)
        try player.addLayer(bytes: pianoBytes, id: c)
        XCTAssertEqual(player.layerIDs, [a, b, c])
    }

    func testRemoveLayerKeepsOrderOfRest() throws {
        let player = PianoPlayer()
        let (a, b) = (UUID(), UUID())
        try player.addLayer(bytes: pianoBytes, id: a)
        try player.addSampleLayer(bytes: sampleBytes, id: b)
        player.removeLayer(id: a)
        XCTAssertEqual(player.layerIDs, [b])
        player.removeLayer(id: b)
        XCTAssertTrue(player.layerIDs.isEmpty)
    }

    /// Channel sound replacement: remove the slot's layer, re-add under the
    /// SAME id — the engine must accept it (this is assignToChannel's flow).
    func testReplaceSoundUnderSameSlotID() throws {
        let player = PianoPlayer()
        let slot = UUID()
        try player.addLayer(bytes: pianoBytes, id: slot)
        player.removeLayer(id: slot)
        try player.addSampleLayer(bytes: sampleBytes, id: slot)
        XCTAssertEqual(player.layerIDs, [slot])
    }

    func testGainMuteFXBySlotID() throws {
        let player = PianoPlayer()
        let id = UUID()
        try player.addLayer(bytes: pianoBytes, id: id)
        player.setLayerGain(0.5, id: id)
        player.setLayerMuted(true, id: id)
        var fx = PianoPlayer.LayerFX()
        fx.attackNorm = 0.4
        player.setLayerFX(fx, id: id)
        XCTAssertEqual(player.layerFX(id: id), fx)
        // Unknown id: no crash, default FX.
        XCTAssertEqual(player.layerFX(id: UUID()), PianoPlayer.LayerFX())
    }

    func testMarkersFromBothSourceKinds() throws {
        let player = PianoPlayer()
        try player.addLayer(bytes: pianoBytes, id: UUID())
        let pianoMarkers = player.markers
        XCTAssertFalse(pianoMarkers.isEmpty)
        try player.addSampleLayer(bytes: sampleBytes, id: UUID())
        XCTAssertTrue(player.markers.count > pianoMarkers.count)
    }
}
