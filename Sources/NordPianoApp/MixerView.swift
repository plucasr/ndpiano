import SwiftUI
import NordPianoEngine

/// One mixer channel strip per selected piano: volume fader, 3-band EQ knobs
/// (low/mid/high) and toggle+knob rows for filter, compressor and reverb.
struct MixerView: View {
    @EnvironmentObject private var model: PlayerModel

    private var selected: [PlayerModel.PianoEntry] {
        model.selected.sorted { $0.name < $1.name }
    }

    var body: some View {
        if selected.isEmpty { EmptyView() } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(selected) { entry in
                        ChannelStrip(entry: entry)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .background(NordColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct ChannelStrip: View {
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
        VStack(spacing: 6) {
            Text(entry.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NordColor.text)
                .lineLimit(1)
                .frame(width: 104)

            HStack(spacing: 8) {
                // Volume fader
                VSlider(value: Binding(
                    get: { Double(model.gains[entry.url] ?? 1) },
                    set: { model.setGain(Float($0), for: entry) }
                ), range: 0...1.5)
                .frame(height: 72)

                VStack(spacing: 4) {
                    // 3-band EQ
                    HStack(spacing: 8) {
                        Knob(value: Binding(
                            get: { fx.eqLow }, set: { v in update { $0.eqLow = v } }
                        ), label: "LOW", range: -1...1)
                        Knob(value: Binding(
                            get: { fx.eqMid }, set: { v in update { $0.eqMid = v } }
                        ), label: "MID", range: -1...1)
                        Knob(value: Binding(
                            get: { fx.eqHigh }, set: { v in update { $0.eqHigh = v } }
                        ), label: "HIGH", range: -1...1)
                    }
                    FxRow(label: "FILTER", isOn: Binding(
                        get: { fx.filterOn }, set: { v in update { $0.filterOn = v } }
                    ), value: Binding(
                        get: { fx.filterNorm }, set: { v in update { $0.filterNorm = v } }
                    ))
                    FxRow(label: "COMP", isOn: Binding(
                        get: { fx.compOn }, set: { v in update { $0.compOn = v } }
                    ), value: Binding(
                        get: { fx.compAmount }, set: { v in update { $0.compAmount = v } }
                    ))
                    FxRow(label: "REVERB", isOn: Binding(
                        get: { fx.reverbOn }, set: { v in update { $0.reverbOn = v } }
                    ), value: Binding(
                        get: { fx.reverbMix }, set: { v in update { $0.reverbMix = v } }
                    ))
                }
            }
        }
        .padding(8)
        .frame(width: 170)
        .background(NordColor.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(NordColor.red.opacity(0.25), lineWidth: 1))
    }
}

/// Toggle + knob on one row (filter / compressor / reverb).
private struct FxRow: View {
    @Binding var isOn: Bool
    @Binding var value: Double
    let label: String

    init(label: String, isOn: Binding<Bool>, value: Binding<Double>) {
        self.label = label
        _isOn = isOn
        _value = value
    }

    var body: some View {
        HStack(spacing: 6) {
            Toggle(label, isOn: $isOn)
                .toggleStyle(.checkbox)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(isOn ? NordColor.red : NordColor.subtext)
                .frame(width: 62, alignment: .leading)
            Knob(value: $value, label: "")
                .disabled(!isOn)
                .opacity(isOn ? 1 : 0.35)
        }
    }
}

/// Drag vertically to turn. `range` is −1…1 for EQ, 0…1 for FX amounts.
private struct Knob: View {
    @Binding var value: Double
    let label: String
    var range: ClosedRange<Double> = 0...1
    @State private var startValue = 0.0
    @State private var dragging = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(NordColor.card)
                    .overlay(Circle().stroke(NordColor.red.opacity(value == 0 ? 0.2 : 0.7), lineWidth: 1))
                // needle: -135°…+135° across the range
                Rectangle()
                    .fill(NordColor.red)
                    .frame(width: 2, height: 10)
                    .offset(y: -7)
                    .rotationEffect(.degrees(-135 + 270 * normalized))
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        if !dragging { startValue = value; dragging = true }
                        let span = range.upperBound - range.lowerBound
                        let next = startValue - d.translation.height / 120 * span
                        value = max(range.lowerBound, min(range.upperBound, next))
                    }
                    .onEnded { _ in dragging = false }
            )
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(NordColor.subtext)
            }
        }
    }

    private var normalized: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}

/// Vertical slider (rotated horizontal one — enough for a fader).
private struct VSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        Slider(value: $value, in: range)
            .rotationEffect(.degrees(-90))
            .frame(width: 72, height: 20)
            .tint(NordColor.red)
    }
}
