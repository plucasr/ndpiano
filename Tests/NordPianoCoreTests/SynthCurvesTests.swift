import XCTest
@testable import NordPianoCore
@testable import NordPianoEngine

/// Pure (no audio) checks for the synth curves, zone table, voice priority
/// and saved-data migration.
final class SynthCurvesTests: XCTestCase {
    func testEnvelopeCurvesHitNordAnchors() {
        XCTAssertEqual(SynthCurves.attackSeconds(64.0 / 127), 1.02, accuracy: 0.01)
        XCTAssertEqual(SynthCurves.attackSeconds(0), 0.0005, accuracy: 0.0001)
        XCTAssertEqual(SynthCurves.decaySeconds(96.0 / 127), 10, accuracy: 0.05)
        XCTAssertEqual(SynthCurves.decaySeconds(1), 45, accuracy: 0.01)
        // Between anchors: monotonic.
        XCTAssertLessThan(SynthCurves.decaySeconds(0.3), SynthCurves.decaySeconds(0.31))
    }

    func testCutoffCurveMatchesNordDisplay() {
        XCTAssertEqual(SynthCurves.cutoffHz(64.0 / 127), 554, accuracy: 80) // Nord shows 554 Hz
        XCTAssertEqual(SynthCurves.cutoffHz(96.0 / 127), 3500, accuracy: 400)
        XCTAssertEqual(SynthCurves.cutoffNorm(hz: SynthCurves.cutoffHz(0.42)), 0.42, accuracy: 1e-9)
    }

    func testNs4ZonesWithThreeSplits() {
        // Splits at C3 / C4 / C5 → zones [0,47] [48,59] [60,71] [72,127].
        let points = [(enabled: true, position: 2), (enabled: true, position: 4), (enabled: true, position: 6)]
        XCTAssertEqual(Ns4Zones.keyRange(kbZone: 0, split: true, points: points), 0...47) // 1ooo
        XCTAssertEqual(Ns4Zones.keyRange(kbZone: 3, split: true, points: points), 48...71) // o11o
        XCTAssertEqual(Ns4Zones.keyRange(kbZone: 8, split: true, points: points), 60...127) // oo11
        XCTAssertEqual(Ns4Zones.keyRange(kbZone: 5, split: true, points: points), 0...127) // 1111
        // Master split off: whole keyboard regardless of the zone value.
        XCTAssertEqual(Ns4Zones.keyRange(kbZone: 0, split: false, points: points), 0...127)
    }

    func testNs4ZonesSingleSplit() {
        // Only the middle split (C4) on: kbZone 0 = "11oo" → below C4.
        let points = [(enabled: false, position: 0), (enabled: true, position: 4), (enabled: false, position: 0)]
        XCTAssertEqual(Ns4Zones.keyRange(kbZone: 0, split: true, points: points), 0...59)
        XCTAssertEqual(Ns4Zones.keyRange(kbZone: 6, split: true, points: points), 60...127)
    }

    func testVoicePriorityWinner() {
        let held: [(note: Int, velocity: Int)] = [(60, 100), (72, 90), (55, 80)]
        XCTAssertEqual(SynthVoicePriority.last.winner(held)?.note, 55)
        XCTAssertEqual(SynthVoicePriority.low.winner(held)?.note, 55)
        XCTAssertEqual(SynthVoicePriority.high.winner(held)?.note, 72)
        XCTAssertNil(SynthVoicePriority.last.winner([]))
    }

    /// Scenes saved before the curve change keep their sound: the old filter
    /// knob (200·90^n Hz) and LFO rate (1+9n Hz) are re-expressed.
    func testLayerFXMigratesVersion1Curves() throws {
        let json = #"{"filterOn": true, "filterNorm": 0.5, "lfoRate": 0.5, "lfoDepth": 0.4}"#
        let fx = try JSONDecoder().decode(PianoPlayer.LayerFX.self, from: Data(json.utf8))
        XCTAssertEqual(SynthCurves.cutoffHz(fx.filterNorm), 200 * pow(90, 0.5), accuracy: 1)
        XCTAssertEqual(SynthCurves.lfoHz(fx.lfoRate), 5.5, accuracy: 0.01)
        XCTAssertEqual(fx.fxVersion, 2)
        // Round trip of current data is lossless (no second migration).
        let again = try JSONDecoder().decode(PianoPlayer.LayerFX.self, from: JSONEncoder().encode(fx))
        XCTAssertEqual(again, fx)
    }
}

final class ArpSequencerTests: XCTestCase {
    private let chord: [(note: Int, velocity: Int)] = [(64, 90), (60, 100), (67, 80)] // pressed out of order

    private func run(_ mode: SynthArpMode, _ dir: SynthArpDirection, octaves: Int = 1, steps: Int) -> [[Int]] {
        var seq = ArpSequencer()
        return (0..<steps).map { _ in seq.next(held: chord, mode: mode, direction: dir, octaves: octaves).map(\.note) }
    }

    func testArpUpDownUpDown() {
        XCTAssertEqual(run(.arp, .up, steps: 4).flatMap { $0 }, [60, 64, 67, 60])
        XCTAssertEqual(run(.arp, .down, steps: 4).flatMap { $0 }, [67, 64, 60, 67])
        // Ping-pong doesn't repeat the turning notes.
        XCTAssertEqual(run(.arp, .upDown, steps: 6).flatMap { $0 }, [60, 64, 67, 64, 60, 64])
    }

    func testArpOctaveRange() {
        XCTAssertEqual(run(.arp, .up, octaves: 2, steps: 7).flatMap { $0 }, [60, 64, 67, 72, 76, 79, 60])
    }

    func testPolyMovesChordThroughOctaves() {
        XCTAssertEqual(run(.poly, .up, octaves: 2, steps: 3), [[60, 64, 67], [72, 76, 79], [60, 64, 67]])
        XCTAssertEqual(run(.gate, .up, octaves: 3, steps: 2), [[60, 64, 67], [60, 64, 67]])
    }

    func testRandomStaysInChordAndKeepsVelocity() {
        var seq = ArpSequencer()
        for _ in 0..<50 {
            let step = seq.next(held: chord, mode: .arp, direction: .random, octaves: 1)
            XCTAssertEqual(step.count, 1)
            XCTAssertTrue(chord.contains { $0.note == step[0].note && $0.velocity == step[0].velocity })
        }
    }
}
