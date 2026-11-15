import SwiftUI
import NordPianoEngine

/// One mixer channel strip per channel, in channel order: volume fader, mute,
/// and an FX button opening the full per-channel effects editor (ChannelFXPanel).
/// Tapping a strip selects it as the target of the sidebar's "→" assign button.
struct MixerView: View {
    @EnvironmentObject private var model: PlayerModel

    var body: some View {
        if model.channels.isEmpty { EmptyView() } else {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(model.channels) { channel in
                        ChannelStrip(channel: channel)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .frame(height: 208)
            .background(NordColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct ChannelStrip: View {
    @EnvironmentObject private var model: PlayerModel
    let channel: PlayerModel.ChannelState
    @State private var showFX = false

    private var entry: PlayerModel.PianoEntry { channel.entry }
    private var isMuted: Bool { model.muted.contains(entry.url) }
    private var isSelected: Bool { model.selectedChannelID == channel.id }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(entry.name)
                    .font(NordFont.font(10, weight: .semibold))
                    .foregroundStyle(NordColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button { model.removeChannel(channel) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(NordFont.font(10))
                        .foregroundStyle(NordColor.subtext)
                }
                .buttonStyle(.plain)
                .help("Remove from mix")
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 8) {
                // Volume fader + mute
                VStack(spacing: 3) {
                    Fader(value: Binding(
                        get: { Double(model.gains[entry.url] ?? 1) },
                        set: { v in model.setGain(Float(v), for: channel) }
                    ), range: 0...1.5)
                    Text("VOL")
                        .font(NordFont.font(7, weight: .medium))
                        .foregroundStyle(NordColor.subtext)
                    Button { model.toggleMute(channel) } label: {
                        Text("M")
                            .font(NordFont.font(8, weight: .bold))
                            .frame(width: 20, height: 13)
                            .background(isMuted ? NordColor.red : Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(isMuted ? .white : NordColor.subtext)
                    }
                    .buttonStyle(.plain)
                    .help(isMuted ? "Unmute" : "Mute")
                }
                .frame(maxHeight: .infinity)

                // FX button opens the full per-channel effects editor.
                Button { showFX = true } label: {
                    Text("FX")
                        .font(NordFont.font(9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 20)
                        .background(NordColor.red, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Edit channel effects")
                .popover(isPresented: $showFX, arrowEdge: .bottom) {
                    ChannelFXPanel(channel: channel)
                        .environmentObject(model)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 110)
        .background(NordColor.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(NordColor.red.opacity(isSelected ? 0.9 : 0.25), lineWidth: isSelected ? 2 : 1))
        .opacity(isMuted ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedChannelID = channel.id }
        .animation(.easeInOut(duration: 0.15), value: isMuted)
    }
}

/// Vertical volume fader: custom track + thumb (a rotated Slider never lays out right).
/// Shared by the mixer strips and the scenes column's MASTER fader.
struct Fader: View {
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
                    .frame(width: 6)
                    .padding(.vertical, 6)
                // active fill
                Capsule()
                    .fill(NordColor.red)
                    .frame(width: 6, height: h - thumbY)
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
        .frame(width: 30)
        .frame(maxHeight: .infinity)
    }
}
