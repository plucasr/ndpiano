import XCTest
@testable import NordMoog

final class MoogVoiceTests: XCTestCase {
    private func render(_ voice: MoogVoice, seconds: Double) -> [Float] {
        let frames = Int(seconds * voice.sampleRate)
        var buffer = [Float](repeating: 0, count: frames)
        return buffer.withUnsafeMutableBufferPointer { out in
            voice.render(into: out, frames: frames)
            return Array(out)
        }
    }

    private func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }

    func testNoteOnRendersAudio() {
        let voice = MoogVoice()
        voice.noteOn(note: 69, velocity: 100)
        let audio = render(voice, seconds: 0.5)
        XCTAssertGreaterThan(rms(audio), 0.01, "a held note must produce audible output")
        XCTAssertTrue(audio.allSatisfy { $0.isFinite }, "output must stay finite")
        XCTAssertTrue(audio.allSatisfy { abs($0) < 4 }, "output must not blow up")
    }

    func testNoteOffDecaysToSilence() {
        let voice = MoogVoice()
        voice.noteOn(note: 69, velocity: 100)
        _ = render(voice, seconds: 0.2)
        voice.noteOff(note: 69)
        let tail = render(voice, seconds: 2)
        XCTAssertLessThan(rms(Array(tail.suffix(1000))), 0.001,
                          "after release the voice must decay to silence")
        XCTAssertTrue(voice.isSilent)
    }

    func testGlideApproachesTargetGradually() {
        var patch = MoogPatch.lead
        patch.glideSeconds = 0.5
        let voice = MoogVoice(patch: patch)
        voice.noteOn(note: 69, velocity: 100)
        voice.noteOff(note: 69)
        voice.noteOn(note: 81, velocity: 100)
        var early = [Float](repeating: 0, count: 64)
        early.withUnsafeMutableBufferPointer { voice.render(into: $0, frames: 64) }
        let soon = voice.pitchHz
        _ = render(voice, seconds: 2)
        let settled = voice.pitchHz
        XCTAssertLessThan(soon, settled - 1, "glide on: pitch must start below the target")
        XCTAssertEqual(settled, MoogVoice.noteHz(81), accuracy: 1,
                       "glide must settle at the target note")
    }

    func testNoGlideSnapsToTarget() {
        var patch = MoogPatch.lead
        patch.glideSeconds = 0
        let voice = MoogVoice(patch: patch)
        voice.noteOn(note: 69, velocity: 100)
        voice.noteOff(note: 69)
        voice.noteOn(note: 81, velocity: 100)
        var block = [Float](repeating: 0, count: 64)
        block.withUnsafeMutableBufferPointer { voice.render(into: $0, frames: 64) }
        XCTAssertEqual(voice.pitchHz, MoogVoice.noteHz(81), accuracy: 0.01)
    }

    func testFilterEnvelopeOpensCutoff() {
        // Base cutoff far below the note's fundamental: with no env sweep the
        // note is choked to near silence; a strong positive sweep lets the
        // attack through, so the swept note must be much louder.
        func loudness(_ patch: MoogPatch) -> Double {
            let voice = MoogVoice(patch: patch)
            voice.noteOn(note: 69, velocity: 100)
            return rms(render(voice, seconds: 0.1))
        }
        var swept = MoogPatch.lead
        swept.cutoffHz = 100
        swept.resonance = 0
        swept.keyTrack = 0
        swept.filterEnvOctaves = 4
        var flat = swept
        flat.filterEnvOctaves = 0
        XCTAssertGreaterThan(loudness(swept), loudness(flat) * 3,
                             "a positive env sweep must open the filter")
    }

    func testPatchCodableRoundTrip() throws {
        var patch = MoogPatch.lead
        patch.cutoffHz = 777
        patch.osc3Level = 0.5
        let data = try JSONEncoder().encode(patch)
        XCTAssertEqual(try JSONDecoder().decode(MoogPatch.self, from: data), patch)
    }
}
