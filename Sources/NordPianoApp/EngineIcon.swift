import SwiftUI

/// Thin-stroke line icons for the engine panels' display areas, drawn to share
/// one stroke weight and scale: grand piano (side view), organ drawbars,
/// synth sine wave.
struct EngineIcon: View {
    enum Kind {
        case piano, organ, synth
    }

    let kind: Kind

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            let shape: any Shape = switch kind {
            case .piano: GrandPianoShape()
            case .organ: DrawbarsShape()
            case .synth: SineWaveShape()
            }
            ctx.stroke(shape.path(in: rect),
                       with: .color(NordColor.subtext),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 120, height: 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NordColor.background)
    }
}

/// Unit-space helpers: shapes describe themselves in a 0…1 box.
private func pt(_ r: CGRect, _ x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: r.minX + CGFloat(x) * r.width, y: r.minY + CGFloat(y) * r.height)
}

/// Grand piano from the side: open lid, curved body, three legs.
private struct GrandPianoShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        // Open lid: from the body's left edge up to the lid tip.
        p.move(to: pt(r, 0.14, 0.50))
        p.addLine(to: pt(r, 0.60, 0.10))
        // Lid prop stick.
        p.move(to: pt(r, 0.42, 0.32))
        p.addLine(to: pt(r, 0.42, 0.52))
        // Body: left edge, long curve to the tail, round down, bottom edge back.
        p.move(to: pt(r, 0.06, 0.42))
        p.addLine(to: pt(r, 0.06, 0.60))
        p.move(to: pt(r, 0.06, 0.42))
        p.addQuadCurve(to: pt(r, 0.92, 0.38), control: pt(r, 0.55, 0.26))
        p.addQuadCurve(to: pt(r, 0.94, 0.52), control: pt(r, 0.97, 0.40))
        p.addLine(to: pt(r, 0.94, 0.56))
        p.addLine(to: pt(r, 0.06, 0.60))
        // Keyboard lip on the left.
        p.move(to: pt(r, 0.02, 0.54))
        p.addLine(to: pt(r, 0.10, 0.54))
        // Legs.
        for x in [0.16, 0.52, 0.86] {
            p.move(to: pt(r, x, x == 0.86 ? 0.58 : 0.62))
            p.addLine(to: pt(r, x, 0.90))
        }
        return p
    }
}

/// Hammond-style drawbars: rails with knobs at different registrations.
private struct DrawbarsShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let knobs: [Double] = [0.30, 0.55, 0.22, 0.62, 0.42]
        for (i, knobY) in knobs.enumerated() {
            let x = 0.18 + Double(i) * 0.16
            p.move(to: pt(r, x, 0.15))
            p.addLine(to: pt(r, x, 0.85))
            // Knob: short thick horizontal cap — drawn as a small square.
            let w = 0.055, h = 0.075
            p.addRoundedRect(in: CGRect(x: pt(r, x - w, knobY - h).x, y: pt(r, x, knobY - h).y,
                                        width: CGFloat(2 * w) * r.width, height: CGFloat(2 * h) * r.height),
                             cornerSize: CGSize(width: 2, height: 2))
        }
        return p
    }
}

/// Sine wave with a small modulation dot (the classic synth glyph).
private struct SineWaveShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let cycles = 1.5
        for i in 0...60 {
            let x = 0.06 + Double(i) / 60 * 0.88
            let y = 0.55 - 0.22 * sin(Double(i) / 60 * cycles * 2 * .pi)
            if i == 0 { p.move(to: pt(r, x, y)) } else { p.addLine(to: pt(r, x, y)) }
        }
        // Modulation dot, top right.
        p.addEllipse(in: CGRect(x: pt(r, 0.80, 0.10).x, y: pt(r, 0, 0.10).y,
                                width: 0.07 * r.width, height: 0.07 * r.width))
        return p
    }
}
