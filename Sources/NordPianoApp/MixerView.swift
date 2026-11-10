import SwiftUI
import NordPianoEngine

/// One mixer channel strip per selected piano: volume fader, 3-band EQ (low/mid/hi)
/// and toggle+knob rows for filter, compressor and reverb.
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
            .fixedSize(horizontal: false, vertical: true)
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
        let isMuted = model.muted.contains(entry.url)
        return VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NordColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button { model.select(entry) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(NordColor.subtext)
                }
                .buttonStyle(.plain)
                .help("Remove from mix")
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 6) {
                // Volume fader + mute
                VStack(spacing: 3) {
                    Fader(value: Binding(
                        get: { Double(model.gains[entry.url] ?? 1) },
                        set: { v in model.setGain(Float(v), for: entry) }
                    ), range: 0...1.5)
                    Text("VOL")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(NordColor.subtext)
                    Button { model.toggleMute(entry) } label: {
                        Text("M")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 20, height: 13)
                            .background(isMuted ? NordColor.red : Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(isMuted ? .white : NordColor.subtext)
                    }
                    .buttonStyle(.plain)
                    .help(isMuted ? "Unmute" : "Mute")
                }
                .frame(maxHeight: .infinity)

                // EQ + FX column: one EQ knob per FX row, divider between.
                HStack(alignment: .center, spacing: 8) {
                    VStack(spacing: 9) {
                        Knob(value: Binding(
                            get: { fx.eqLow }, set: { v in update { $0.eqLow = v } }
                        ), label: "low", range: -1...1)
                        Knob(value: Binding(
                            get: { fx.eqMid }, set: { v in update { $0.eqMid = v } }
                        ), label: "mid", range: -1...1)
                        Knob(value: Binding(
                            get: { fx.eqHigh }, set: { v in update { $0.eqHigh = v } }
                        ), label: "hi", range: -1...1)
                    }
                    Rectangle()
                        .fill(NordColor.red.opacity(0.25))
                        .frame(width: 1, height: 108)
                    VStack(alignment: .trailing, spacing: 6) {
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
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 166)
        .background(NordColor.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(NordColor.red.opacity(0.25), lineWidth: 1))
        .opacity(isMuted ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.15), value: isMuted)
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
        HStack(alignment: .top, spacing: 6) {
            Toggle(label, isOn: $isOn)
                .toggleStyle(PillToggleStyle(labelBelow: true))
            Knob(value: $value, label: "")
                .disabled(!isOn)
                .opacity(isOn ? 1 : 0.35)
        }
        .frame(height: 34)
    }
}

/// Vertical volume fader: custom track + thumb (a rotated Slider never lays out right).
private struct Fader: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private var normalized: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let thumbY = (1 - normalized) * (h - 12) + 6
            ZStack(alignment: .top) {
                // track
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 4)
                    .padding(.vertical, 6)
                // active fill
                Capsule()
                    .fill(NordColor.red)
                    .frame(width: 4, height: h - thumbY)
                    .offset(y: thumbY)
                // thumb
                Circle()
                    .fill(NordColor.red)
                    .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    .frame(width: 12, height: 12)
                    .position(x: geo.size.width / 2, y: thumbY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        let span = range.upperBound - range.lowerBound
                        let n = 1 - (d.location.y - 6) / max(1, h - 12)
                        value = max(range.lowerBound, min(range.upperBound,
                                                          range.lowerBound + n * span))
                    }
            )
        }
        .frame(width: 20)
        .frame(maxHeight: .infinity)
    }
}
