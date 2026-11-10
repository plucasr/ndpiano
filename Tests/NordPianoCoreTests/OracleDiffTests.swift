import XCTest
@testable import NordPianoCore

/// FNV-1a over the little-endian bytes of each Int32, matching the TS oracle's fnv1a.
private func fnv1a(_ values: [Int32]) -> String {
    var h: UInt32 = 0x811c9dc5
    for v in values {
        var x = UInt32(bitPattern: v)
        for _ in 0..<4 {
            h ^= x & 0xff
            h = h &* 0x01000193
            x >>= 8
        }
    }
    return String(format: "%08x", h)
}

final class OracleDiffTests: XCTestCase {
    private struct Fixture {
        var bytes: [UInt8]
        var json: [String: Any]
    }

    private func loadFixture() throws -> Fixture {
        let thisFile = URL(fileURLWithPath: #filePath)
        let dir = thisFile.deletingLastPathComponent().appendingPathComponent("Fixtures")
        let data = try Data(contentsOf: dir.appendingPathComponent("oracle.npno"))
        let jsonData = try Data(contentsOf: dir.appendingPathComponent("expected.json"))
        return Fixture(bytes: [UInt8](data), json: try JSONSerialization.jsonObject(with: jsonData) as! [String: Any])
    }

    func testDirectoryMatchesOracle() throws {
        let f = try loadFixture()
        let dir = try readNspDirectory(f.bytes)

        XCTAssertEqual(dir.version, f.json["version"] as! Int)
        XCTAssertEqual(dir.channels, f.json["channels"] as! Int)
        XCTAssertEqual(dir.blockWords, f.json["blockWords"] as! Int)

        let zones = (f.json["zones"] as! [[String: Any]]).map {
            NspZone(rootNote: $0["rootNote"] as! Int, lowNote: $0["lowNote"] as! Int, highNote: $0["highNote"] as! Int)
        }
        XCTAssertEqual(readNspZones(f.bytes).map { [$0.rootNote, $0.lowNote, $0.highNote] }, zones.map { [$0.rootNote, $0.lowNote, $0.highNote] })

        let expectedStrokes = f.json["strokes"] as! [[String: Any]]
        XCTAssertEqual(dir.strokes.count, expectedStrokes.count)
        for (stroke, exp) in zip(dir.strokes, expectedStrokes) {
            XCTAssertEqual(stroke.zone, exp["zone"] as! Int, "stroke \(stroke.index) zone")
            XCTAssertEqual(stroke.velocityFrom, exp["velocityFrom"] as! Int, "stroke \(stroke.index) floor")
            XCTAssertEqual(stroke.flags, exp["flags"] as! Int, "stroke \(stroke.index) flags")
            XCTAssertEqual(stroke.release, exp["release"] as! Bool, "stroke \(stroke.index) release")
            XCTAssertEqual(stroke.frames, exp["frames"] as! Int, "stroke \(stroke.index) frames")
            XCTAssertEqual(stroke.blocks, exp["blocks"] as! Int, "stroke \(stroke.index) blocks")
            if let loop = exp["loop"] as? [String: Any] {
                XCTAssertEqual(stroke.loop?.start, loop["start"] as? Int)
                XCTAssertEqual(stroke.loop?.length, loop["length"] as? Int)
            } else {
                XCTAssertNil(stroke.loop)
            }
            if let decay = exp["loopDecay"] as? Double {
                XCTAssertEqual(stroke.loopDecay ?? -1, decay, accuracy: 1e-12, "stroke \(stroke.index) decay")
            } else {
                XCTAssertNil(stroke.loopDecay)
            }
            XCTAssertEqual(stroke.history, (exp["history"] as! [[Int]]).map { $0.map(Int32.init) })
        }
    }

    func testDecodedAudioMatchesOracle() throws {
        let f = try loadFixture()
        let dir = try readNspDirectory(f.bytes)
        let expectedStrokes = f.json["strokes"] as! [[String: Any]]
        for (stroke, exp) in zip(dir.strokes, expectedStrokes) {
            let pcm = try decodeNspStroke(f.bytes, dir: dir, stroke: stroke)
            XCTAssertEqual(pcm.count, dir.channels, "stroke \(stroke.index) channels")
            XCTAssertEqual(pcm[0].count, stroke.frames, "stroke \(stroke.index) frame count")
            XCTAssertEqual(fnv1a(pcm[0]), exp["ch0Hash"] as! String, "stroke \(stroke.index) ch0 hash")
            if dir.channels == 2 {
                XCTAssertEqual(fnv1a(pcm[1]), exp["ch1Hash"] as! String, "stroke \(stroke.index) ch1 hash")
            }
            XCTAssertEqual(pcm[0].prefix(8).map { Int($0) }, exp["ch0First8"] as! [Int])
            XCTAssertEqual(pcm[0].suffix(8).map { Int($0) }, exp["ch0Last8"] as! [Int])
            let peak = pcm.flatMap { $0.map(abs) }.max()!
            XCTAssertEqual(Int(peak), exp["peak"] as! Int, "stroke \(stroke.index) peak")
        }
    }

    func testStrokeForMatchesLayerSwitch() throws {
        let f = try loadFixture()
        let dir = try readNspDirectory(f.bytes)
        // Zone 0 has floors 0 and 12 dB: the switch sits at their midpoint (6 dB of
        // attenuation ≈ velocity where 40·log10(127/v) = 6 → v ≈ 127·10^(−6/40) ≈ 92).
        let hard = strokeFor(dir, zone: 0, velocity: 127)
        let soft = strokeFor(dir, zone: 0, velocity: 20)
        XCTAssertEqual(hard?.velocityFrom, 0)
        XCTAssertEqual(soft?.velocityFrom, 60) // 12 dB in 0.2 dB steps
        // The switch sits at 6 dB of attenuation: velocity 89 (≈30.09 steps) passes it,
        // velocity 90 (≈29.89 steps) does not.
        let mid = strokeFor(dir, zone: 0, velocity: 89)
        XCTAssertEqual(mid?.velocityFrom, 60)
        let below = strokeFor(dir, zone: 0, velocity: 90)
        XCTAssertEqual(below?.velocityFrom, 0)
    }
}

extension OracleDiffTests {
    func testIdentityMatchesWriter() throws {
        let f = try loadFixture()
        let id = readNspIdentity(f.bytes)
        XCTAssertEqual(id?.name, "OracleFixture")
        // The writer stamps version 6.x at 0x14 (little-endian u16).
        XCTAssertEqual(id?.version, "6.00")
    }
}
