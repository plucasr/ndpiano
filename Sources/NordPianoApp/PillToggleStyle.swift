import SwiftUI

/// iOS-style pill switch: rounded capsule track with a white circle knob,
/// like the reference design. Track is gray when off, colored when on.
/// Label can sit to the side of the switch or centered below it.
struct PillToggleStyle: ToggleStyle {
    var onColor: Color = Color(red: 0.35, green: 0.85, blue: 0.45) // green
    var labelBelow = false

    private let width: CGFloat = 40
    private let height: CGFloat = 20
    private let knobPadding: CGFloat = 2.5

    private var labelFont: Font {
        .system(size: labelBelow ? 7 : 9, weight: .semibold)
    }

    private func label(_ configuration: Configuration) -> some View {
        configuration.label
            .font(labelFont)
            .foregroundStyle(configuration.isOn ? NordColor.text : NordColor.subtext)
    }

    private func track(_ configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? onColor : Color.white.opacity(0.22))
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .padding(knobPadding)
            }
            .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
    }

    func makeBody(configuration: Configuration) -> some View {
        if labelBelow {
            VStack(spacing: 3) {
                track(configuration)
                label(configuration)
                    .lineLimit(1)
                    .frame(width: width)
            }
        } else {
            HStack(spacing: 6) {
                label(configuration)
                track(configuration)
            }
        }
    }
}
