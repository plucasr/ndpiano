import SwiftUI

/// Drag vertically to turn. `range` is −1…1 for EQ, 0…1 for FX amounts.
/// Shared by the mixer channel strips and the global FX strip.
struct Knob: View {
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
                    .frame(width: 2, height: 9)
                    .offset(y: -6)
                    .rotationEffect(.degrees(-135 + 270 * normalized))
            }
            .frame(width: 22, height: 22)
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
