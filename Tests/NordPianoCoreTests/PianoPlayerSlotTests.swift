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

final class LayerFXCodableTests: XCTestCase {
    /// FX persisted before the synth modifiers existed must decode with the new
    /// fields at their defaults, not fail.
    func testLegacyJSONDecodesWithSynthDefaults() throws {
        let legacy = """
        {"filterOn":true,"filterNorm":0.5,"compOn":false,"compAmount":0.3,
         "driveOn":false,"driveNorm":0.3,"driveMix":0.5,
         "delayOn":false,"delayTime":0.25,"delayFeedback":0.3,"delayMix":0.2,
         "reverbOn":true,"reverbMix":0.4,"reverbSize":0.3,
         "attackNorm":0.1,"releaseGain":0.5,"eqLow":0.2,"eqMid":0,"eqHigh":-0.1}
        """.data(using: .utf8)!
        let fx = try JSONDecoder().decode(PianoPlayer.LayerFX.self, from: legacy)
        XCTAssertTrue(fx.filterOn)
        XCTAssertEqual(fx.eqLow, 0.2)
        XCTAssertFalse(fx.oneShot)
        XCTAssertFalse(fx.monoOn)
        XCTAssertEqual(fx.glideNorm, 0)
        XCTAssertEqual(fx.lfoDepth, 0)
        XCTAssertEqual(fx.lfoRate, 0.3)
    }

    func testRoundTripKeepsSynthFields() throws {
        var fx = PianoPlayer.LayerFX()
        fx.oneShot = true
        fx.monoOn = true
        fx.glideNorm = 0.6
        fx.lfoDepth = 0.7
        fx.lfoRate = 0.9
        let data = try JSONEncoder().encode(fx)
        XCTAssertEqual(try JSONDecoder().decode(PianoPlayer.LayerFX.self, from: data), fx)
    }
}
