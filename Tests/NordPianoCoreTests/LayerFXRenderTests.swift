import XCTest
@testable import NordPianoCore
@testable import NordPianoEngine

/// The in-render voice features behind the new LayerFX fields: resonant SVF
/// filtering and octave shift. Records the master bus around one held note of
/// the sample fixture and compares measurements across FX settings.
final class LayerFXRenderTests: XCTestCase {

    private var fixture: [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/soft-wave-lead.nsmp4")
        return try! [UInt8](Data(contentsOf: url))
    }

    /// Play note 60 for ~0.6 s with the given channel FX; returns the recorded
    /// peak and zero-crossing count (a rough pitch proxy).
    private func recordNote(velocity: Int = 100,
                            controllers: (PianoPlayer) -> Void = { _ in },
                            configure: (inout PianoPlayer.LayerFX) -> Void) throws -> (peak: Int, crossings: Int) {
        let player = PianoPlayer(midiInput: false)
        try player.start()
        defer { player.stopRecording() }
        let id = UUID()
        try player.addSampleLayer(bytes: fixture, id: id)
        var fx = PianoPlayer.LayerFX()
        configure(&fx)
        player.setLayerFX(fx, id: id)
        controllers(player)
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-render-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try player.startRecording(to: wav)
        player.noteOn(60, velocity: velocity)
        Thread.sleep(forTimeInterval: 0.7)
        player.stopRecording()
        player.noteOff(60)
        let data = [UInt8](try Data(contentsOf: wav).dropFirst(4096))
        var peak = 0, crossings = 0, prev = 0
        var i = 0
        while i + 1 < data.count {
            let s = Int(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8))
            peak = max(peak, abs(s))
            if prev <= 0 && s > 0 { crossings += 1 }
            prev = s
            i += 2
        }
        return (peak, crossings)
    }

    /// A low SVF cutoff must gut the note; resonance must stay stable.
    func testResonantFilterAttenuatesAndStaysStable() throws {
        let open = try recordNote { _ in }
        var closed = try recordNote { fx in
            fx.filterOn = true
            fx.filterNorm = SynthCurves.cutoffNorm(hz: 200)
        }
        XCTAssertGreaterThan(open.peak, 500, "fixture should sound unfiltered")
        // The fixture is bass-heavy, so peak barely moves — the zero-crossing
        // rate is the sensitive measure of the removed high harmonics.
        XCTAssertLessThan(closed.crossings, Int(Double(open.crossings) * 0.6),
                          "low cutoff should strip harmonics (open \(open.crossings), closed \(closed.crossings))")
        XCTAssertLessThan(closed.peak, open.peak)
        closed = try recordNote { fx in
            fx.filterOn = true
            fx.filterNorm = SynthCurves.cutoffNorm(hz: 1900)
            fx.filterRes = 0.95 // near self-oscillation: must not blow up
            fx.fltEnvAmt = 0.8
            fx.fltEnvAtk = 0.3
            fx.fltEnvDcy = 0.3
            fx.fltEnvSus = 0.4
        }
        XCTAssertLessThan(closed.peak, 32767)
        XCTAssertGreaterThan(closed.peak, 0)
    }

    /// +12 semitones doubles the zero-crossing rate (±30%).
    func testOctaveShiftDoublesCrossingRate() throws {
        let base = try recordNote { _ in }
        let up = try recordNote { fx in fx.octaveShift = 12 }
        XCTAssertGreaterThan(base.crossings, 20)
        let ratio = Double(up.crossings) / Double(base.crossings)
        XCTAssertEqual(ratio, 2, accuracy: 0.6,
                       "base \(base.crossings) crossings, +12 \(up.crossings)")
    }

    /// Aftertouch → level morph: −1 at full pressure silences the layer.
    func testAftertouchLevelMorph() throws {
        let morph: (inout PianoPlayer.LayerFX) -> Void = { $0.atToLevel = -1 }
        let none = try recordNote(configure: morph)
        let full = try recordNote(controllers: { $0.aftertouch(127) }, configure: morph)
        XCTAssertGreaterThan(none.peak, 500)
        XCTAssertLessThan(full.peak, none.peak / 10, "none \(none.peak), full AT \(full.peak)")
    }

    /// Control pedal → cutoff morph opens a closed filter.
    func testPedalCutoffMorphOpensFilter() throws {
        let morph: (inout PianoPlayer.LayerFX) -> Void = {
            $0.filterOn = true
            $0.filterNorm = SynthCurves.cutoffNorm(hz: 200)
            $0.pedalToCutoff = 1 - $0.filterNorm
        }
        let heel = try recordNote(configure: morph)
        let toe = try recordNote(controllers: { $0.controlPedal(127) }, configure: morph)
        XCTAssertGreaterThan(toe.crossings, Int(Double(heel.crossings) * 1.4),
                             "heel \(heel.crossings), toe \(toe.crossings)")
    }

    /// Filter-envelope velocity: a soft note gets a smaller sweep. Same soft
    /// velocity both runs (so the sample and gain match); with envelope
    /// velocity on, the sweep stays under the fixture's 2nd harmonic and the
    /// crossing rate falls back toward the fundamental.
    func testFilterEnvelopeVelocity() throws {
        func env(_ envVel: Double) -> (inout PianoPlayer.LayerFX) -> Void {
            { fx in
                fx.filterOn = true
                fx.filterNorm = SynthCurves.cutoffNorm(hz: 200)
                fx.fltEnvAmt = 1
                fx.fltEnvAtk = 0
                fx.fltEnvSus = 1
                fx.fltEnvVel = envVel
            }
        }
        let fixed = try recordNote(velocity: 20, configure: env(0))
        let scaled = try recordNote(velocity: 20, configure: env(1))
        XCTAssertLessThan(Double(scaled.crossings), Double(fixed.crossings) * 0.7,
                          "fixed sweep \(fixed.crossings), velocity-scaled \(scaled.crossings)")
    }

    // MARK: - Synth-path regressions

    /// Record a performance: `play` drives the player while the master bus is
    /// written to disk; returns mono 16-bit samples (header skipped).
    private func perform(configure: (inout PianoPlayer.LayerFX) -> Void,
                         play: (PianoPlayer) -> Void) throws -> [Int16] {
        let player = PianoPlayer(midiInput: false)
        try player.start()
        defer { player.stopRecording() }
        let id = UUID()
        try player.addSampleLayer(bytes: fixture, id: id)
        var fx = PianoPlayer.LayerFX()
        configure(&fx)
        player.setLayerFX(fx, id: id)
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-perf-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try player.startRecording(to: wav)
        play(player)
        player.stopRecording()
        let data = [UInt8](try Data(contentsOf: wav).dropFirst(4096))
        return stride(from: 0, to: data.count - 1, by: 2).map {
            Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
        }
    }

    private func peak(_ samples: ArraySlice<Int16>) -> Int {
        samples.map { abs(Int($0)) }.max() ?? 0
    }

    /// A key released mid-attack must fade out (it used to keep climbing and
    /// stall at a constant level forever on looped samples).
    func testReleaseDuringAttackFades() throws {
        let samples = try perform(configure: {
            $0.attackNorm = 0.6 // ~2.2 s attack
            $0.releaseTimeNorm = 0 // shortest release
        }, play: { p in
            p.noteOn(60, velocity: 110)
            Thread.sleep(forTimeInterval: 0.4)
            p.noteOff(60)
            Thread.sleep(forTimeInterval: 0.8)
        })
        let tail = samples.suffix(samples.count / 5) // last ~0.24 s
        XCTAssertGreaterThan(peak(samples[...]), 50, "attack should have produced sound")
        XCTAssertLessThan(peak(tail), 5, "released note must die out")
    }

    /// Amp decay to zero sustain silences a held note.
    func testAmpDecayToZeroSustain() throws {
        let samples = try perform(configure: {
            $0.ampSustain = 0
            $0.ampDecay = 0.2 // ~70 ms
        }, play: { p in
            p.noteOn(60, velocity: 110)
            Thread.sleep(forTimeInterval: 0.7)
        })
        XCTAssertGreaterThan(peak(samples.prefix(samples.count / 4)), 300)
        XCTAssertLessThan(peak(samples.suffix(samples.count / 3)), 5, "held note should have decayed away")
    }

    /// Keyboard zone: notes outside keyLow…keyHigh are silent.
    func testKeyZoneSilencesOutsideRange() throws {
        let outside = try perform(configure: { $0.keyLow = 72 }, play: { p in
            p.noteOn(60, velocity: 110)
            Thread.sleep(forTimeInterval: 0.3)
        })
        let inside = try perform(configure: { $0.keyHigh = 72 }, play: { p in
            p.noteOn(60, velocity: 110)
            Thread.sleep(forTimeInterval: 0.3)
        })
        XCTAssertEqual(peak(outside[...]), 0)
        XCTAssertGreaterThan(peak(inside[...]), 300)
    }

    /// A fully open filter must pass the top end (the old SVF was capped near
    /// 7 kHz, so "open" still dulled the sound).
    func testOpenFilterIsTransparent() throws {
        let open = try recordNote { _ in }
        let filtered = try recordNote { fx in
            fx.filterOn = true
            fx.filterNorm = 1
        }
        XCTAssertEqual(Double(filtered.crossings), Double(open.crossings), accuracy: Double(open.crossings) * 0.1,
                       "open \(open.crossings), fully-open filter \(filtered.crossings)")
        XCTAssertGreaterThan(Double(filtered.peak), Double(open.peak) * 0.8)
    }

    /// Each filter type renders stably at high resonance.
    func testAllFilterTypesStable() throws {
        for type in SynthFilterType.allCases {
            let r = try recordNote { fx in
                fx.filterOn = true
                fx.filterType = type.rawValue
                fx.filterNorm = SynthCurves.cutoffNorm(hz: 800)
                fx.filterRes = 0.95
                fx.filterHPNorm = SynthCurves.cutoffNorm(hz: 200)
            }
            XCTAssertGreaterThan(r.peak, 0, "\(type.label) silent")
            XCTAssertLessThan(r.peak, 32767, "\(type.label) clipped/blew up")
        }
    }

    /// The channel LFO's rate must not depend on how many notes are held: count
    /// amplitude-gate cycles of a square LFO for one note vs a 4-note chord.
    func testLfoRateIndependentOfVoiceCount() throws {
        func gateCycles(_ notes: [Int]) throws -> Int {
            let samples = try perform(configure: {
                $0.lfoDepth = 1
                $0.lfoDest = SynthLfoDest.amp.rawValue
                $0.lfoShape = SynthLfoShape.square.rawValue
                $0.lfoRate = log(4 / 0.05) / log(400) // 4 Hz
            }, play: { p in
                for n in notes { p.noteOn(n, velocity: 110) }
                Thread.sleep(forTimeInterval: 1.2)
            })
            // 25 ms windows of peak level; count gate openings with hysteresis
            // (close below 20 %, open above 60 % of max) so the chord's beating
            // inside an open gate doesn't read as extra cycles.
            let window = 1102
            let levels = stride(from: 0, to: samples.count - window, by: window).map {
                peak(samples[$0..<$0 + window])
            }
            let top = levels.max() ?? 0
            var cycles = 0
            var open = false
            for level in levels {
                if !open && level > top * 6 / 10 { open = true; cycles += 1 }
                if open && level < top * 2 / 10 { open = false }
            }
            return cycles
        }
        let single = try gateCycles([60])
        let chord = try gateCycles([60, 64, 67, 71])
        XCTAssertGreaterThan(single, 2)
        XCTAssertEqual(Double(chord), Double(single), accuracy: 1.5, "single \(single), chord \(chord)")
    }

    /// Pitch vibrato modulates pitch, not level: peak stays ~constant.
    func testVibratoIsPitchNotLevel() throws {
        let plain = try recordNote { _ in }
        let vib = try recordNote { fx in
            fx.vibMode = SynthVibratoMode.on.rawValue
            fx.vibDepth = 1
            fx.vibRate = 1
        }
        XCTAssertGreaterThan(Double(vib.peak), Double(plain.peak) * 0.85, "vibrato shouldn't dip the level")
    }

    /// Pitch-bend range is per layer: range 0 ignores the wheel, 12 = octave.
    func testBendRangePerLayer() throws {
        let base = try recordNote { _ in }
        let up = try recordNote(controllers: { $0.pitchBend(2) }) { fx in
            fx.bendUp = 12
        }
        let ignored = try recordNote(controllers: { $0.pitchBend(2) }) { fx in
            fx.bendUp = 0
        }
        XCTAssertEqual(Double(up.crossings) / Double(base.crossings), 2, accuracy: 0.6)
        XCTAssertEqual(Double(ignored.crossings), Double(base.crossings), accuracy: Double(base.crossings) * 0.1)
    }

    /// Mono with low-note priority: a higher key while a low one is held
    /// doesn't take over; releasing a non-sounding key changes nothing.
    func testMonoLowPriorityKeepsLowNote() throws {
        let low = try recordNote { fx in fx.monoOn = true }
        let both = try recordNote(controllers: { _ in }) { fx in
            fx.monoOn = true
            fx.voicePriority = SynthVoicePriority.low.rawValue
        }
        // Same single note sanity (the helper plays one note).
        XCTAssertEqual(Double(both.crossings), Double(low.crossings), accuracy: Double(low.crossings) * 0.1)
        let samples = try perform(configure: {
            $0.monoOn = true
            $0.voicePriority = SynthVoicePriority.low.rawValue
        }, play: { p in
            p.noteOn(60, velocity: 110)
            Thread.sleep(forTimeInterval: 0.1)
            p.noteOn(72, velocity: 110) // ignored: low priority
            Thread.sleep(forTimeInterval: 0.6)
        })
        var crossings = 0
        var prev: Int16 = 0
        for s in samples.suffix(samples.count / 2) {
            if prev <= 0 && s > 0 { crossings += 1 }
            prev = s
        }
        // Half the recording vs the helper's full ~0.7 s note: roughly half the
        // crossings — an octave jump would double it instead.
        let expected = Double(low.crossings) * Double(samples.count / 2) / Double(samples.count)
        XCTAssertLessThan(Double(crossings), expected * 1.4, "high note took over (\(crossings) vs ~\(expected))")
    }

    // MARK: - Arpeggiator

    /// Count note onsets: 10 ms peak windows, hysteresis gate (open > 50 %,
    /// closed < 10 % of max).
    private func onsets(_ samples: ArraySlice<Int16>, reference: Int? = nil) -> Int {
        let window = 441
        let base = samples.startIndex
        let levels = stride(from: 0, to: samples.count - window, by: window).map {
            peak(samples[(base + $0)..<(base + $0 + window)])
        }
        let top = reference ?? levels.max() ?? 0
        guard top > 0 else { return 0 }
        var count = 0
        var open = false
        for level in levels {
            if !open && level > top / 2 { open = true; count += 1 }
            if open && level < top / 10 { open = false }
        }
        return count
    }

    private func arpFX(_ fx: inout PianoPlayer.LayerFX) {
        fx.arpOn = true
        fx.arpRate = log(5) / log(30) // 5 steps/s
        fx.arpGate = 0.4
        fx.releaseTimeNorm = 0
    }

    /// Holding a chord with the arp on plays separate steps at the set rate.
    func testArpStepsAtRate() throws {
        let samples = try perform(configure: arpFX) { p in
            p.noteOn(60, velocity: 110)
            p.noteOn(64, velocity: 110)
            Thread.sleep(forTimeInterval: 1.25)
        }
        let n = onsets(samples[...])
        XCTAssertEqual(Double(n), 6, accuracy: 1.5, "expected ~6 steps in 1.25 s at 5/s, got \(n)")
    }

    /// Key-up stops the arp; with HOLD it keeps running.
    func testArpStopsOnKeyUpUnlessHold() throws {
        func tailOnsets(hold: Bool) throws -> Int {
            let samples = try perform(configure: { fx in self.arpFX(&fx); fx.arpHold = hold }) { p in
                p.noteOn(60, velocity: 110)
                Thread.sleep(forTimeInterval: 0.3)
                p.noteOff(60)
                Thread.sleep(forTimeInterval: 1.0)
            }
            // The last ~0.85 s, thresholds relative to the whole take's level
            // (the step sounding at key-up may still be fading at the start).
            return onsets(samples.suffix(samples.count * 2 / 3), reference: peak(samples[...]))
        }
        XCTAssertEqual(try tailOnsets(hold: false), 0)
        XCTAssertGreaterThanOrEqual(try tailOnsets(hold: true), 3)
    }
}
