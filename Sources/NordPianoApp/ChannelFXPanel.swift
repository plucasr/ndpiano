import SwiftUI
import NordPianoEngine

/// Per-channel FX editor, opened from the mixer's FX button: every effect of
/// the layer's chain in one popover, sections separated by red dividers.
/// Mirrors the global FX strip's language (knobs + vertical pill toggles).
struct ChannelFXPanel: View {
    @EnvironmentObject private var model: PlayerModel
    let entry: PlayerModel.PianoEntry

    private var fx: PianoPlayer.LayerFX {
        model.layerFX[entry.url] ?? PianoPlayer.LayerFX()
    }

    private func update(_ mutate: (inout PianoPlayer.LayerFX) -> Void) {
        var f = fx
        mutate(&f)
        model.setLayerFX(f, for: entry.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.name)
                .font(NordFont.font(13, weight: .bold))
                .foregroundStyle(NordColor.text)

            // Fixed ideal width + horizontal scroll: without this the popover
            // compresses sections to fit the screen edge and texts wrap one
            // letter per line ("F B T", vertical cut-off titles).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 16) {
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
                        n <= 0.001 ? "0" : "\(Int(300 * n * n))ms"
                    }
                }
                .effectDivider()

                section(label: "RELEASE") {
                    panelKnob(value: Binding(
                        get: { fx.releaseGain }, set: { v in update { $0.releaseGain = v } }
                    ), caption: "AMT") { "\(Int($0 * 100))%" }
                }
                .effectDivider()

                section(label: "FILTER", isOn: Binding(
                    get: { fx.filterOn }, set: { v in update { $0.filterOn = v } }
                )) {
                    panelKnob(value: Binding(
                        get: { fx.filterNorm }, set: { v in update { $0.filterNorm = v } }
                    ), caption: "CUT") { n in
                        n > 0.97 ? "∞" : "\(Int(200 * pow(90, n)))"
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
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(18)
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
        .frame(height: 96)
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
            Knob(value: value, label: caption, range: range, diameter: 46)
        }
    }
}
