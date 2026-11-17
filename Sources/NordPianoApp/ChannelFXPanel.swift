import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NordPianoEngine
import NordMoog

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Per-channel FX editor, opened from the mixer's FX button: every effect of
/// the layer's chain in one popover, sections separated by red dividers.
/// Mirrors the global FX strip's language (knobs + vertical pill toggles).
struct ChannelFXPanel: View {
    @EnvironmentObject private var model: PlayerModel
    let channel: PlayerModel.ChannelState

    private var fx: PianoPlayer.LayerFX {
        model.layerFX[channel.entry.url] ?? PianoPlayer.LayerFX()
    }

    private func update(_ mutate: (inout PianoPlayer.LayerFX) -> Void) {
        var f = fx
        mutate(&f)
        model.setLayerFX(f, for: channel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            browseHeader

            let gateCCs = model.drawbarCCs(for: channel)
            if !gateCCs.isEmpty { drawbarRow(count: gateCCs.count) }

            // Fixed rows: tone (EQ…CHORUS), inserts (FILTER…REVERB), playing
            // (keyboard zone, pitch); synth channels add the voice/filter/amp
            // row and the modulation row. fixedSize keeps the popover from
            // compressing sections against the screen edge.
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) { fxRowA }
                HStack(alignment: .center, spacing: 14) { fxRowB }
                HStack(alignment: .center, spacing: 14) { playRow }
                if isMoog {
                    HStack(alignment: .center, spacing: 14) { moogOscRow }
                    HStack(alignment: .center, spacing: 14) { moogFilterRow }
                } else if isSynth {
                    HStack(alignment: .center, spacing: 14) { synthSections }
                    HStack(alignment: .center, spacing: 14) { modulationRow }
                    HStack(alignment: .center, spacing: 14) { arpRow }
                }
            }
            .fixedSize()
        }
        .padding(18)
    }

    /// The classic Hammond drawbar footages (16′ … 1′), shown under the faders.
    private static let drawbarLabels = ["16", "5⅓", "8", "4", "2⅔", "2", "1⅗", "1⅓", "1"]

    /// Drawbar row for gated SFZ organs: one 0–8 fader per gate controller,
    /// wired through the model into the layer's CC gate state.
    private func drawbarRow(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DRAWBARS")
                .font(NordFont.font(9, weight: .semibold))
                .foregroundStyle(NordColor.red)
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<count, id: \.self) { index in
                    VStack(spacing: 2) {
                        Text("\(Int(fx.drawbars[safe: index] ?? 0))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(NordColor.subtext)
                        Fader(value: Binding(
                            get: { fx.drawbars[safe: index] ?? 0 },
                            set: { model.setDrawbar(index, position: $0, for: channel) }
                        ), range: 0...8)
                        .frame(height: 70)
                        Text(ChannelFXPanel.drawbarLabels[safe: index] ?? "\(index + 1)")
                            .font(NordFont.font(7, weight: .medium))
                            .foregroundStyle(NordColor.subtext)
                    }
                }
            }
        }
        .fixedSize()
    }

    private var isSynth: Bool {
        model.catalogEntry(for: channel.entry.url)?.category == .synth
    }

    // MARK: - Moog panel (Phase 4)

    private var isMoog: Bool {
        model.catalogEntry(for: channel.entry.url)?.category == .moog
    }

    private var patch: MoogPatch { model.moogPatch(for: channel) }

    private func updatePatch(_ mutate: (inout MoogPatch) -> Void) {
        var p = patch
        mutate(&p)
        model.setMoogPatch(p, for: channel)
    }

    /// 0…1-style knob on a MoogPatch Double field with an explicit range.
    private func moogKnob(_ key: WritableKeyPath<MoogPatch, Double>, caption: String,
                          range: ClosedRange<Double> = 0...1,
                          readout: @escaping (Double) -> String = { "\(Int($0 * 100))%" }) -> some View {
        panelKnob(value: Binding(get: { patch[keyPath: key] },
                                 set: { v in updatePatch { $0[keyPath: key] = v } }),
                  caption: caption, range: range, readout: readout)
    }

    /// Knob on a MoogPatch Int field.
    private func moogIntKnob(_ key: WritableKeyPath<MoogPatch, Int>, caption: String,
                             range: ClosedRange<Int>,
                             readout: @escaping (Double) -> String) -> some View {
        panelKnob(value: Binding(
            get: { Double(patch[keyPath: key]) },
            set: { v in updatePatch { $0[keyPath: key] = min(range.upperBound, max(range.lowerBound, Int(v.rounded()))) } }
        ), caption: caption, range: Double(range.lowerBound)...Double(range.upperBound), readout: readout)
    }

    /// SAW/PULSE chip for one oscillator.
    private func waveChip(_ key: WritableKeyPath<MoogPatch, Bool>) -> some View {
        chipMenu(["SAW", "PULSE"], selected: patch[keyPath: key] ? 1 : 0) { i in
            updatePatch { $0[keyPath: key] = i == 1 }
        }
    }

    /// Row 1: the oscillator bank (each osc with its mixer level) + noise.
    @ViewBuilder private var moogOscRow: some View {
        section(label: "OSC 1") {
            HStack(spacing: 12) {
                waveChip(\.osc1Pulse)
                moogKnob(\.osc1Level, caption: "LVL")
            }
        }
        .effectDivider()
        section(label: "OSC 2") {
            HStack(spacing: 12) {
                waveChip(\.osc2Pulse)
                moogKnob(\.osc2Level, caption: "LVL")
                moogKnob(\.osc2DetuneCents, caption: "DETUNE", range: -50...50) { v in
                    String(format: "%+.0fc", v)
                }
            }
        }
        .effectDivider()
        section(label: "OSC 3") {
            HStack(spacing: 12) {
                waveChip(\.osc3Pulse)
                moogKnob(\.osc3Level, caption: "LVL")
                moogIntKnob(\.osc3Octave, caption: "OCT", range: -1...1) { v in
                    String(format: "%+d", Int(v))
                }
                moogKnob(\.osc3DetuneCents, caption: "DETUNE", range: -50...50) { v in
                    String(format: "%+.0fc", v)
                }
            }
        }
        .effectDivider()
        section(label: "MIXER") {
            HStack(spacing: 12) {
                moogKnob(\.noiseLevel, caption: "NOISE")
                moogKnob(\.pulseWidth, caption: "P.WIDTH", range: 0.1...0.9) { "\(Int($0 * 100))%" }
            }
        }
    }

    /// Row 2: ladder filter, its contour, the amp contour, and output/glide.
    @ViewBuilder private var moogFilterRow: some View {
        section(label: "FILTER") {
            HStack(spacing: 12) {
                moogKnob(\.cutoffHz, caption: "CUTOFF", range: 20...12_000) {
                    SynthCurves.formatHz($0)
                }
                moogKnob(\.resonance, caption: "EMPHASIS")
                moogKnob(\.filterEnvOctaves, caption: "ENV AMT", range: -4...4) { v in
                    String(format: "%+.1foct", v)
                }
                moogKnob(\.keyTrack, caption: "KB TRK")
            }
        }
        .effectDivider()
        section(label: "FILTER CONTOUR") {
            HStack(spacing: 10) {
                moogKnob(\.filterAttack, caption: "A", range: 0...2) { SynthCurves.formatSeconds($0) }
                moogKnob(\.filterDecay, caption: "D", range: 0...2) { SynthCurves.formatSeconds($0) }
                moogKnob(\.filterSustain, caption: "S")
                moogKnob(\.filterRelease, caption: "R", range: 0...2) { SynthCurves.formatSeconds($0) }
            }
        }
        .effectDivider()
        section(label: "AMP CONTOUR") {
            HStack(spacing: 10) {
                moogKnob(\.ampAttack, caption: "A", range: 0...2) { SynthCurves.formatSeconds($0) }
                moogKnob(\.ampDecay, caption: "D", range: 0...2) { SynthCurves.formatSeconds($0) }
                moogKnob(\.ampSustain, caption: "S")
                moogKnob(\.ampRelease, caption: "R", range: 0...2) { SynthCurves.formatSeconds($0) }
            }
        }
        .effectDivider()
        section(label: "OUTPUT") {
            HStack(spacing: 12) {
                moogKnob(\.glideSeconds, caption: "GLIDE", range: 0...0.3) { v in
                    v < 0.001 ? "off" : SynthCurves.formatSeconds(v)
                }
                moogKnob(\.volume, caption: "VOLUME")
            }
        }
    }

    /// Chain row 1: tone-shaping (EQ, envelope, stereo, chorus).
    @ViewBuilder private var fxRowA: some View {
                section(label: "EQ") {
                    HStack(spacing: 12) {
                        panelKnob(value: Binding(
                            get: { fx.eqLow }, set: { v in update { $0.eqLow = v } }
                        ), caption: "lo", range: -1...1)
                        panelKnob(value: Binding(
                            get: { fx.eqMid }, set: { v in update { $0.eqMid = v } }
                        ), caption: "mi", range: -1...1)
                        panelKnob(value: Binding(
                            get: { fx.eqHigh }, set: { v in update { $0.eqHigh = v } }
                        ), caption: "hi", range: -1...1)
                    }
                }
                .effectDivider()

                section(label: "ATTACK") {
                    panelKnob(value: Binding(
                        get: { fx.attackNorm }, set: { v in update { $0.attackNorm = v } }
                    ), caption: "TIME") { n in
                        n <= 0.001 ? "0" : SynthCurves.formatSeconds(10 * n * n * n)
                    }
                }
                .effectDivider()

                section(label: "RELEASE") {
                    HStack(spacing: 12) {
                        panelKnob(value: Binding(
                            get: { fx.releaseTimeNorm }, set: { v in update { $0.releaseTimeNorm = v } }
                        ), caption: "TIME") { n in
                            // Time to silence (≈ 6.9 time constants).
                            SynthCurves.formatSeconds(6.9 * 0.05 * pow(60, n))
                        }
                        panelKnob(value: Binding(
                            get: { fx.releaseGain }, set: { v in update { $0.releaseGain = v } }
                        ), caption: "AMT") { "\(Int($0 * 100))%" }
                    }
                }
                .effectDivider()

                section(label: "PAN") {
                    panelKnob(value: Binding(
                        get: { fx.pan }, set: { v in update { $0.pan = v } }
                    ), caption: "POS", range: -1...1) { v in
                        v == 0 ? "C" : v < 0 ? "L\(Int(-v * 100))" : "R\(Int(v * 100))"
                    }
                }
                .effectDivider()

                section(label: "CHORUS", isOn: Binding(
                    get: { fx.chorusOn }, set: { v in update { $0.chorusOn = v } }
                )) {
                    HStack(spacing: 12) {
                        panelKnob(value: Binding(
                            get: { fx.chorusRate }, set: { v in update { $0.chorusRate = v } }
                        ), caption: "RATE") { n in String(format: "%.1f", 0.2 + n * 3.8) + "Hz" }
                        panelKnob(value: Binding(
                            get: { fx.chorusDepth }, set: { v in update { $0.chorusDepth = v } }
                        ), caption: "DEPTH") { "\(Int($0 * 100))%" }
                    }
                }
    }

    /// Chain row 2: the insert effects (filter through reverb).
    @ViewBuilder private var fxRowB: some View {
                section(label: "FILTER", isOn: Binding(
                    get: { fx.filterOn }, set: { v in update { $0.filterOn = v } }
                )) {
                    HStack(spacing: 12) {
                        panelKnob(value: Binding(
                            get: { fx.filterNorm }, set: { v in update { $0.filterNorm = v } }
                        ), caption: "CUT") { SynthCurves.formatHz(SynthCurves.cutoffHz($0)) }
                        panelKnob(value: Binding(
                            get: { fx.filterRes }, set: { v in update { $0.filterRes = v } }
                        ), caption: "RES") { "\(Int($0 * 100))%" }
                    }
                }
                .effectDivider()

                section(label: "COMP", isOn: Binding(
                    get: { fx.compOn }, set: { v in update { $0.compOn = v } }
                )) {
                    panelKnob(value: Binding(
                        get: { fx.compAmount }, set: { v in update { $0.compAmount = v } }
                    ), caption: "AMT") { "\(Int($0 * 100))%" }
                }
                .effectDivider()

                section(label: "DRIVE", isOn: Binding(
                    get: { fx.driveOn }, set: { v in update { $0.driveOn = v } }
                )) {
                    HStack(spacing: 12) {
                        panelKnob(value: Binding(
                            get: { fx.driveNorm }, set: { v in update { $0.driveNorm = v } }
                        ), caption: "DRIVE") { "\(Int($0 * 20))" }
                        panelKnob(value: Binding(
                            get: { fx.driveMix }, set: { v in update { $0.driveMix = v } }
                        ), caption: "MIX") { "\(Int($0 * 100))%" }
                    }
                }
                .effectDivider()

                section(label: "DELAY", isOn: Binding(
                    get: { fx.delayOn }, set: { v in update { $0.delayOn = v } }
                )) {
                    HStack(spacing: 12) {
                        panelKnob(value: Binding(
                            get: { min(1, max(0, fx.delayTime / 2)) },
                            set: { v in update { $0.delayTime = v * 2 } }
                        ), caption: "TIME") { _ in String(format: "%.2f", fx.delayTime) + "s" }
                        panelKnob(value: Binding(
                            get: { fx.delayFeedback }, set: { v in update { $0.delayFeedback = v } }
                        ), caption: "FBT") { "\(Int($0 * 100))%" }
                        panelKnob(value: Binding(
                            get: { fx.delayMix }, set: { v in update { $0.delayMix = v } }
                        ), caption: "MIX") { "\(Int($0 * 100))%" }
                    }
                }
                .effectDivider()

                section(label: "REVERB", isOn: Binding(
                    get: { fx.reverbOn }, set: { v in update { $0.reverbOn = v } }
                )) {
                    HStack(spacing: 12) {
                        panelKnob(value: Binding(
                            get: { fx.reverbMix }, set: { v in update { $0.reverbMix = v } }
                        ), caption: "MIX") { "\(Int($0 * 100))%" }
                        panelKnob(value: Binding(
                            get: { fx.reverbSize }, set: { v in update { $0.reverbSize = v } }
                        ), caption: "SIZE") { _ in String(format: "%.1f", 0.3 + fx.reverbSize * 6.7) + "s" }
                    }
                }
    }

    /// Playing row (every channel): keyboard zone + sustain-pedal switch, and
    /// pitch (transpose, wheel range).
    @ViewBuilder private var playRow: some View {
                section(label: "KEYS") {
                    HStack(spacing: 12) {
                        panelKnob(value: intBinding(\.keyLow, in: 0...127, clampTo: { min($0, fx.keyHigh) }),
                                  caption: "LOW", range: 0...127) { SynthCurves.noteName(Int($0)) }
                        panelKnob(value: intBinding(\.keyHigh, in: 0...127, clampTo: { max($0, fx.keyLow) }),
                                  caption: "HIGH", range: 0...127) { SynthCurves.noteName(Int($0)) }
                        VStack(spacing: 4) {
                            Toggle("", isOn: Binding(
                                get: { !fx.ignoresSustain }, set: { v in update { $0.ignoresSustain = !v } }
                            ))
                            .toggleStyle(VerticalPillToggleStyle())
                            .labelsHidden()
                            caption("SUS PED")
                        }
                    }
                }
                .effectDivider()

                section(label: "PITCH") {
                    HStack(spacing: 12) {
                        panelKnob(value: intBinding(\.octaveShift, in: -36...36),
                                  caption: "TRANSP", range: -36...36) { v in
                            let st = Int(v)
                            return st == 0 ? "0" : st % 12 == 0 ? "\(st > 0 ? "+" : "")\(st / 12)oct" : "\(st > 0 ? "+" : "")\(st)st"
                        }
                        panelKnob(value: intBinding(\.bendUp, in: 0...24), caption: "BEND +",
                                  range: 0...24) { "\(Int($0))st" }
                        panelKnob(value: intBinding(\.bendDown, in: 0...24), caption: "BEND −",
                                  range: 0...24) { "\(Int($0))st" }
                    }
                }
    }

    /// Synth row 1: voice mode, filter model, filter envelope, amp envelope,
    /// one-shot — only for synth channels.
    @ViewBuilder private var synthSections: some View {
                    section(label: "VOICE") {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                chipMenu(["POLY", "MONO", "LEGATO"],
                                         selected: fx.monoOn ? (fx.legato ? 2 : 1) : 0) { i in
                                    update { $0.monoOn = i > 0; $0.legato = i == 2 }
                                }
                                chipMenu(SynthVoicePriority.allCases.map(\.label), selected: fx.voicePriority) { i in
                                    update { $0.voicePriority = i }
                                }
                                .disabled(!fx.monoOn)
                                .opacity(fx.monoOn ? 1 : 0.4)
                            }
                            panelKnob(value: Binding(
                                get: { fx.glideNorm }, set: { v in update { $0.glideNorm = v } }
                            ), caption: "GLIDE") { n in
                                n <= 0.01 ? "off" : "\(Int(400 * n))ms"
                            }
                            .disabled(!fx.monoOn)
                            .opacity(fx.monoOn ? 1 : 0.4)
                        }
                    }
                    .effectDivider()

                    section(label: "FILTER TYPE", isOn: Binding(
                        get: { fx.filterOn }, set: { v in update { $0.filterOn = v } }
                    )) {
                        HStack(spacing: 12) {
                            chipMenu(SynthFilterType.allCases.map(\.label), selected: fx.filterType) { i in
                                update { $0.filterType = i }
                            }
                            panelKnob(value: Binding(
                                get: { fx.filterKeyTrack }, set: { v in update { $0.filterKeyTrack = v } }
                            ), caption: "KB TRK") { "\(Int($0 * 100))%" }
                            if fx.filterType == SynthFilterType.lpHp.rawValue {
                                panelKnob(value: Binding(
                                    get: { fx.filterHPNorm }, set: { v in update { $0.filterHPNorm = v } }
                                ), caption: "HP") { SynthCurves.formatHz(SynthCurves.cutoffHz($0)) }
                            }
                        }
                    }
                    .effectDivider()

                    section(label: "FILTER ENV") {
                        HStack(spacing: 10) {
                            panelKnob(value: Binding(
                                get: { fx.fltEnvAmt }, set: { v in update { $0.fltEnvAmt = v } }
                            ), caption: "AMT", range: -1...1) { v in
                                String(format: "%+.1foct", 4 * v)
                            }
                            envKnob(\.fltEnvAtk, caption: "A") { SynthCurves.formatSeconds(SynthCurves.attackSeconds($0)) }
                            envKnob(\.fltEnvDcy, caption: "D") { n in
                                n >= 1 ? "∞" : SynthCurves.formatSeconds(SynthCurves.decaySeconds(n))
                            }
                            envKnob(\.fltEnvSus, caption: "S") { "\(Int($0 * 100))%" }
                            envKnob(\.fltEnvRls, caption: "R") { SynthCurves.formatSeconds(SynthCurves.decaySeconds($0)) }
                            envKnob(\.fltEnvVel, caption: "VEL") { "\(Int($0 * 100))%" }
                        }
                        .disabled(!fx.filterOn)
                        .opacity(fx.filterOn ? 1 : 0.4)
                    }
                    .effectDivider()

                    section(label: "AMP ENV") {
                        HStack(spacing: 10) {
                            envKnob(\.ampDecay, caption: "DECAY") {
                                SynthCurves.formatSeconds(SynthCurves.decaySeconds($0))
                            }
                            .disabled(fx.ampSustain >= 1)
                            .opacity(fx.ampSustain >= 1 ? 0.4 : 1)
                            envKnob(\.ampSustain, caption: "SUS") { "\(Int($0 * 100))%" }
                            envKnob(\.velToLevel, caption: "VEL") { "\(Int($0 * 100))%" }
                        }
                    }
                    .effectDivider()

                    section(label: "MODE", isOn: Binding(
                        get: { fx.oneShot }, set: { v in update { $0.oneShot = v } }
                    )) {
                        Text("ONE-SHOT")
                            .font(NordFont.font(7, weight: .medium))
                            .foregroundStyle(NordColor.subtext)
                            .multilineTextAlignment(.center)
                            .frame(width: 46)
                    }
    }

    /// Synth row 2: LFO, vibrato, and the morph amounts (what the mod wheel,
    /// aftertouch, control pedal and velocity do to cutoff and level).
    @ViewBuilder private var modulationRow: some View {
                    section(label: "LFO", isOn: Binding(
                        get: { fx.lfoDepth > 0 },
                        set: { on in update { $0.lfoDepth = on ? max(0.3, $0.lfoDepth) : 0 } }
                    )) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                chipMenu(SynthLfoDest.allCases.map(\.label), selected: fx.lfoDest) { i in
                                    update { $0.lfoDest = i }
                                }
                                chipMenu(SynthLfoShape.allCases.map(\.label), selected: fx.lfoShape) { i in
                                    update { $0.lfoShape = i }
                                }
                            }
                            panelKnob(value: Binding(
                                get: { fx.lfoDepth }, set: { v in update { $0.lfoDepth = v } }
                            ), caption: "DEPTH") { "\(Int($0 * 100))%" }
                            panelKnob(value: Binding(
                                get: { fx.lfoRate }, set: { v in update { $0.lfoRate = v } }
                            ), caption: "RATE") { n in
                                let hz = SynthCurves.lfoHz(n)
                                return String(format: hz < 1 ? "%.2f" : "%.1f", hz) + "Hz"
                            }
                        }
                    }
                    .effectDivider()

                    section(label: "VIBRATO") {
                        HStack(spacing: 12) {
                            chipMenu(SynthVibratoMode.allCases.map(\.label), selected: fx.vibMode) { i in
                                update { $0.vibMode = i }
                            }
                            Group {
                                panelKnob(value: Binding(
                                    get: { fx.vibDepth }, set: { v in update { $0.vibDepth = v } }
                                ), caption: "DEPTH") { "±\(Int(SynthCurves.vibratoSemitones($0) * 100))c" }
                                panelKnob(value: Binding(
                                    get: { fx.vibRate }, set: { v in update { $0.vibRate = v } }
                                ), caption: "RATE") { String(format: "%.1fHz", SynthCurves.vibratoHz($0)) }
                                panelKnob(value: Binding(
                                    get: { min(1, fx.vibDelay / 3) }, set: { v in update { $0.vibDelay = v * 3 } }
                                ), caption: "DELAY") { _ in String(format: "%.1fs", fx.vibDelay) }
                                .disabled(fx.vibMode != SynthVibratoMode.delayed.rawValue)
                                .opacity(fx.vibMode == SynthVibratoMode.delayed.rawValue ? 1 : 0.4)
                            }
                            .disabled(fx.vibMode == 0)
                            .opacity(fx.vibMode == 0 ? 0.4 : 1)
                        }
                    }
                    .effectDivider()

                    section(label: "MORPH → CUTOFF") {
                        HStack(spacing: 8) {
                            morphKnob(\.wheelToCutoff, caption: "WHL")
                            morphKnob(\.atToCutoff, caption: "AT")
                            morphKnob(\.pedalToCutoff, caption: "PED")
                            morphKnob(\.velToCutoff, caption: "VEL")
                        }
                    }
                    .effectDivider()

                    section(label: "MORPH → LEVEL") {
                        HStack(spacing: 8) {
                            morphKnob(\.wheelToLevel, caption: "WHL")
                            morphKnob(\.atToLevel, caption: "AT")
                            morphKnob(\.pedalToLevel, caption: "PED")
                        }
                    }
    }

    /// Synth row 3: the arpeggiator.
    @ViewBuilder private var arpRow: some View {
                    section(label: "ARPEGGIATOR", isOn: Binding(
                        get: { fx.arpOn }, set: { v in update { $0.arpOn = v } }
                    )) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                chipMenu(SynthArpMode.allCases.map(\.label), selected: fx.arpMode) { i in
                                    update { $0.arpMode = i }
                                }
                                chipMenu(SynthArpDirection.allCases.map(\.label), selected: fx.arpDirection) { i in
                                    update { $0.arpDirection = i }
                                }
                                .disabled(fx.arpMode == SynthArpMode.gate.rawValue)
                                .opacity(fx.arpMode == SynthArpMode.gate.rawValue ? 0.4 : 1)
                            }
                            panelKnob(value: intBinding(\.arpOctaves, in: 1...4), caption: "RANGE",
                                      range: 1...4) { "\(Int($0))oct" }
                            panelKnob(value: Binding(
                                get: { fx.arpRate }, set: { v in update { $0.arpRate = v } }
                            ), caption: "RATE") { n in
                                "\(Int(SynthCurves.arpBPM(n).rounded()))bpm"
                            }
                            .help("Steps per second, shown as the tempo where one step is a 16th note")
                            panelKnob(value: Binding(
                                get: { fx.arpGate }, set: { v in update { $0.arpGate = max(0.05, v) } }
                            ), caption: "GATE") { "\(Int($0 * 100))%" }
                            VStack(spacing: 4) {
                                Toggle("", isOn: Binding(
                                    get: { fx.arpHold }, set: { v in update { $0.arpHold = v } }
                                ))
                                .toggleStyle(VerticalPillToggleStyle())
                                .labelsHidden()
                                caption("HOLD")
                            }
                        }
                    }
    }

    /// Title row: the channel's sound with ‹ › to step through the catalog
    /// sounds of its category (same as the mixer's browse popover). The FX
    /// shown follow the sound — each sound keeps its own settings.
    private var browseHeader: some View {
        let context = model.browseContext(for: channel)
        return HStack(spacing: 10) {
            browseButton("chevron.left", delta: -1, enabled: context != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.entry.name)
                    .font(NordFont.font(13, weight: .bold))
                    .foregroundStyle(NordColor.text)
                    .lineLimit(1)
                if let (list, index) = context {
                    Text("\(model.catalogEntry(for: channel.entry.url)?.category.rawValue.uppercased() ?? "") · \(index + 1) / \(list.count)")
                        .font(NordFont.font(8, weight: .medium))
                        .foregroundStyle(NordColor.subtext)
                }
            }
            browseButton("chevron.right", delta: 1, enabled: context != nil)
            Spacer()
            presetButton("square.and.arrow.down", help: "Import FX preset (JSON)") { importPreset() }
            presetButton("square.and.arrow.up", help: "Export FX preset (JSON)") { exportPreset() }
        }
    }

    /// Small header button for preset import/export.
    private func presetButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(NordFont.font(10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 20)
                .background(NordColor.card, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(NordColor.red.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Load a preset JSON and apply it to this channel's sound (kept per
    /// sound, like knob edits).
    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = isMoog
            ? [UTType(filenameExtension: "moog") ?? .json]
            : [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Import an FX preset (JSON)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if isMoog {
                let preset = try MoogPreset.decode(from: Data(contentsOf: url))
                model.setMoogPatch(preset.patch, for: channel)
                model.status = "Preset “\(preset.name)” → \(channel.entry.name)"
            } else {
                let preset = try FXPreset.decode(from: Data(contentsOf: url))
                model.setLayerFX(preset.fx, for: channel)
                model.status = "Preset “\(preset.name)” → \(channel.entry.name)"
            }
        } catch {
            model.status = "Preset import failed: \(error.localizedDescription)"
        }
    }

    /// Save this channel's current FX state as a preset JSON (.moog for moog
    /// channels).
    private func exportPreset() {
        let panel = NSSavePanel()
        if isMoog {
            panel.allowedContentTypes = [UTType(filenameExtension: "moog") ?? .json]
            panel.nameFieldStringValue = "\(channel.entry.name).moog"
        } else {
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(channel.entry.name).json"
        }
        panel.message = "Export the current FX as a preset"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if isMoog {
                try MoogPreset(name: channel.entry.name, patch: patch).encode().write(to: url)
            } else {
                try FXPreset(name: channel.entry.name, fx: fx).encode().write(to: url)
            }
            model.status = "Preset saved: \(url.lastPathComponent)"
        } catch {
            model.status = "Preset export failed: \(error.localizedDescription)"
        }
    }

    private func browseButton(_ icon: String, delta: Int, enabled: Bool) -> some View {
        Button { model.stepChannelSound(channel, delta: delta) } label: {
            Image(systemName: icon)
                .font(NordFont.font(10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 20)
                .background(NordColor.red, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(delta < 0 ? "Previous sound" : "Next sound")
    }

    /// 0…1 knob on a LayerFX field (envelope stages and similar).
    private func envKnob(_ key: WritableKeyPath<PianoPlayer.LayerFX, Double>, caption: String,
                         readout: @escaping (Double) -> String) -> some View {
        panelKnob(value: Binding(get: { fx[keyPath: key] }, set: { v in update { $0[keyPath: key] = v } }),
                  caption: caption, readout: readout)
    }

    /// Bipolar morph amount −1…1 (0 = no morph), smaller knob.
    private func morphKnob(_ key: WritableKeyPath<PianoPlayer.LayerFX, Double>, caption: String) -> some View {
        panelKnob(value: Binding(get: { fx[keyPath: key] }, set: { v in update { $0[keyPath: key] = v } }),
                  caption: caption, range: -1...1) { v in
            abs(v) < 0.005 ? "—" : String(format: "%+d", Int((v * 100).rounded()))
        }
    }

    /// A knob bound to an Int field, rounding as it turns.
    private func intBinding(_ key: WritableKeyPath<PianoPlayer.LayerFX, Int>, in range: ClosedRange<Int>,
                            clampTo: @escaping (Int) -> Int = { $0 }) -> Binding<Double> {
        Binding(
            get: { Double(fx[keyPath: key]) },
            set: { v in
                let n = clampTo(min(range.upperBound, max(range.lowerBound, Int(v.rounded()))))
                update { $0[keyPath: key] = n }
            }
        )
    }

    /// Compact drop-down chip for enumerated settings (filter type, LFO shape…).
    private func chipMenu(_ options: [String], selected: Int,
                          onSelect: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i]) { onSelect(i) }
            }
        } label: {
            Text(options.indices.contains(selected) ? options[selected] : "—")
                .font(NordFont.font(8, weight: .semibold))
                .foregroundStyle(NordColor.text)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(NordColor.card))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(NordColor.red.opacity(0.5), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(NordFont.font(7, weight: .medium))
            .foregroundStyle(NordColor.subtext)
            .lineLimit(1)
            .fixedSize()
    }

    /// One section: title on top, knobs beside a bare vertical pill toggle
    /// (omit `isOn` for always-live sections like EQ/ATTACK/RELEASE).
    private func section<Content: View>(label: String, isOn: Binding<Bool>? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(NordFont.font(9, weight: .semibold))
                .foregroundStyle(NordColor.red)
            HStack(alignment: .center, spacing: 10) {
                content()
                    .disabled(isOn.map { !$0.wrappedValue } ?? false)
                    .opacity(isOn?.wrappedValue ?? true ? 1 : 0.4)
                if let isOn {
                    Toggle("", isOn: isOn)
                        .toggleStyle(VerticalPillToggleStyle())
                        .labelsHidden()
                }
            }
        }
        .frame(height: 84)
    }

    /// Knob with caption below and a live readout above (readout via closure).
    /// Default readout shows the value × 12 (±12 dB for the EQ range −1…1).
    private func panelKnob(value: Binding<Double>, caption: String, range: ClosedRange<Double> = 0...1,
                           readout: @escaping (Double) -> String = { "\(Int($0 * 12))" }) -> some View {
        VStack(spacing: 2) {
            Text(readout(value.wrappedValue))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(NordColor.subtext)
                .lineLimit(1)
                .fixedSize()
            Knob(value: value, label: caption, range: range, diameter: 34)
        }
    }
}
