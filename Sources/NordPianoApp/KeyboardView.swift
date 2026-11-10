import SwiftUI
import NordPianoCore
import NordPianoEngine

/// Clickable 88-key keyboard (MIDI 21...108). Red dots mark the sampled notes
/// (where a zone's recording actually sits). Drag across keys to play.
struct KeyboardView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var draggedNote: Int?

    private static let firstKey = 21, lastKey = 108
    private static let whiteNotes: Set<Int> = [0, 2, 4, 5, 7, 9, 11]

    private func isWhite(_ midi: Int) -> Bool { Self.whiteNotes.contains(midi % 12) }

    private func blackRect(_ midi: Int, whiteW: CGFloat, height: CGFloat) -> CGRect {
        let w = whiteW * 0.62
        // white index of the white key just below this black key
        var whitesBelow = -1
        for m in Self.firstKey...midi where isWhite(m) { whitesBelow += 1 }
        // black key hangs between the surrounding whites
        let x = CGFloat(whitesBelow) * whiteW - w / 2 + whiteW
        return CGRect(x: x, y: 0, width: w, height: height * 0.62)
    }

    private func yFromTop(x: CGFloat, height: CGFloat, inBlackZone: Bool, blackH: CGFloat, rect: CGRect) -> CGFloat { 0 }

    var body: some View {
        Canvas { context, size in
            let whiteW = size.width / 52
            // White keys
            var whiteIdx = 0
            for midi in Self.firstKey...Self.lastKey where isWhite(midi) {
                let x = CGFloat(whiteIdx) * whiteW
                let pressed = model.sounding.contains(midi) || model.uiHeld.contains(midi)
                let path = Path(CGRect(x: x, y: 0, width: whiteW, height: size.height))
                context.fill(path, with: .color(pressed ? NordColor.red : Color(white: 0.96)))
                context.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: 0.5)
                whiteIdx += 1
            }
            // Zone root markers (sampled notes) on white keys
            let sampled = Set(model.markers)
            whiteIdx = 0
            for midi in Self.firstKey...Self.lastKey where isWhite(midi) {
                if sampled.contains(midi) {
                    let dot = Path(ellipseIn: CGRect(x: CGFloat(whiteIdx) * whiteW + whiteW / 2 - 3, y: 6, width: 6, height: 6))
                    context.fill(dot, with: .color(NordColor.red))
                }
                whiteIdx += 1
            }
            // Black keys
            for midi in Self.firstKey...Self.lastKey where !isWhite(midi) {
                let r = blackRect(midi, whiteW: whiteW, height: size.height)
                let pressed = model.sounding.contains(midi) || model.uiHeld.contains(midi)
                let path = Path(r)
                context.fill(path, with: .color(pressed ? NordColor.red : Color(white: 0.08)))
                if sampled.contains(midi) {
                    let dot = Path(ellipseIn: CGRect(x: r.midX - 2.5, y: 6, width: 5, height: 5))
                    context.fill(dot, with: .color(Color.white.opacity(0.85)))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let note = key(at: value.location, size: lastSize)
                    if note != draggedNote {
                        if let old = draggedNote { model.noteOff(old) }
                        if let n = note { model.noteOn(n) }
                        draggedNote = note
                    }
                }
                .onEnded { _ in
                    if let old = draggedNote { model.noteOff(old) }
                    draggedNote = nil
                }
        )
        .onAppear { lastSize = CGSize(width: 920, height: 190) }
        .background(GeometryReader { g in Color.clear.onAppear { lastSize = g.size }.onChange(of: g.size) { lastSize = $0 } })
    }

    @State private var lastSize = CGSize(width: 920, height: 190)

    private func key(at point: CGPoint, size: CGSize) -> Int? {
        guard size.width > 0 else { return nil }
        let whiteW = size.width / 52
        let blackH = size.height * 0.62
        if point.y <= blackH {
            for midi in Self.firstKey...Self.lastKey where !isWhite(midi) {
                let r = blackRect(midi, whiteW: whiteW, height: size.height)
                if r.contains(point) { return midi }
            }
        }
        let idx = min(51, max(0, Int(point.x / whiteW)))
        var seen = -1
        for midi in Self.firstKey...Self.lastKey where isWhite(midi) {
            seen += 1
            if seen == idx { return midi }
        }
        return nil
    }
}
