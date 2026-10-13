import SwiftUI
import MagicWineCore

/// An original vector controller illustration; coordinates describe a 540 × 300 canvas.
struct GamepadDiagram: View {
    let input: GamepadInput
    let connected: Bool

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 540, y: size.height / 300)
            drawController(in: context)
        }
        .opacity(connected ? 1 : 0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Physical controller input")
        .accessibilityValue(connected ? pressedDescription : "No controller connected")
    }

    private var pressedDescription: String {
        let names = GamepadControl.inputs.filter { input.value(for: $0) > 0.05 }.map(\.displayName)
        return names.isEmpty ? "No buttons pressed" : "Active: " + names.joined(separator: ", ")
    }

    private func drawController(in context: GraphicsContext) {
        trigger(in: context, rect: CGRect(x: 144, y: 24, width: 48, height: 27), control: .leftTrigger)
        trigger(in: context, rect: CGRect(x: 348, y: 24, width: 48, height: 27), control: .rightTrigger)
        shoulder(in: context, rect: CGRect(x: 132, y: 48, width: 68, height: 16), control: .leftShoulder)
        shoulder(in: context, rect: CGRect(x: 340, y: 48, width: 68, height: 16), control: .rightShoulder)

        var body = Path()
        body.move(to: CGPoint(x: 174, y: 60))
        body.addCurve(to: CGPoint(x: 118, y: 102), control1: CGPoint(x: 143, y: 58), control2: CGPoint(x: 126, y: 71))
        body.addCurve(to: CGPoint(x: 84, y: 246), control1: CGPoint(x: 99, y: 149), control2: CGPoint(x: 72, y: 210))
        body.addCurve(to: CGPoint(x: 130, y: 264), control1: CGPoint(x: 88, y: 274), control2: CGPoint(x: 112, y: 282))
        body.addCurve(to: CGPoint(x: 197, y: 219), control1: CGPoint(x: 154, y: 246), control2: CGPoint(x: 163, y: 218))
        body.addLine(to: CGPoint(x: 343, y: 219))
        body.addCurve(to: CGPoint(x: 410, y: 264), control1: CGPoint(x: 377, y: 218), control2: CGPoint(x: 386, y: 246))
        body.addCurve(to: CGPoint(x: 456, y: 246), control1: CGPoint(x: 428, y: 282), control2: CGPoint(x: 452, y: 274))
        body.addCurve(to: CGPoint(x: 422, y: 102), control1: CGPoint(x: 468, y: 210), control2: CGPoint(x: 441, y: 149))
        body.addCurve(to: CGPoint(x: 366, y: 60), control1: CGPoint(x: 414, y: 71), control2: CGPoint(x: 397, y: 58))
        body.addCurve(to: CGPoint(x: 174, y: 60), control1: CGPoint(x: 295, y: 67), control2: CGPoint(x: 245, y: 67))
        body.closeSubpath()
        var glow = context
        glow.addFilter(.shadow(color: WineTheme.accent.opacity(0.35), radius: 10))
        glow.fill(body, with: .linearGradient(
            Gradient(colors: [WineTheme.elevated, Color(red: 0.075, green: 0.065, blue: 0.085)]),
            startPoint: CGPoint(x: 270, y: 60), endPoint: CGPoint(x: 270, y: 266)))
        context.stroke(body, with: .color(WineTheme.accent.opacity(0.8)), lineWidth: 1.4)

        stick(in: context, center: CGPoint(x: 166, y: 120), x: input.leftX, y: input.leftY, control: .leftThumb)
        stick(in: context, center: CGPoint(x: 324, y: 181), x: input.rightX, y: input.rightY, control: .rightThumb)
        dpad(in: context)
        button(in: context, center: CGPoint(x: 381, y: 101), radius: 13, control: .y, color: .yellow, label: "Y")
        button(in: context, center: CGPoint(x: 407, y: 127), radius: 13, control: .b, color: .red, label: "B")
        button(in: context, center: CGPoint(x: 381, y: 153), radius: 13, control: .a, color: .green, label: "A")
        button(in: context, center: CGPoint(x: 355, y: 127), radius: 13, control: .x, color: .blue, label: "X")
        button(in: context, center: CGPoint(x: 245, y: 121), radius: 10, control: .back, color: WineTheme.muted, label: "−")
        button(in: context, center: CGPoint(x: 295, y: 121), radius: 10, control: .start, color: WineTheme.muted, label: "+")
        button(in: context, center: CGPoint(x: 270, y: 90), radius: 14, control: .guide, color: WineTheme.accent, label: "⌂")

        callout(in: context, text: "LT", from: CGPoint(x: 167, y: 27), to: CGPoint(x: 86, y: 22))
        callout(in: context, text: "LB", from: CGPoint(x: 144, y: 52), to: CGPoint(x: 60, y: 54))
        callout(in: context, text: "RT", from: CGPoint(x: 375, y: 27), to: CGPoint(x: 454, y: 22))
        callout(in: context, text: "RB", from: CGPoint(x: 398, y: 52), to: CGPoint(x: 480, y: 54))
        callout(in: context, text: "Left Stick", from: CGPoint(x: 139, y: 132), to: CGPoint(x: 45, y: 145))
        callout(in: context, text: "D-Pad", from: CGPoint(x: 179, y: 194), to: CGPoint(x: 44, y: 206))
        callout(in: context, text: "Right Stick", from: CGPoint(x: 351, y: 191), to: CGPoint(x: 486, y: 206))
        callout(in: context, text: "Select", from: CGPoint(x: 245, y: 134), to: CGPoint(x: 230, y: 279))
        callout(in: context, text: "Home", from: CGPoint(x: 270, y: 106), to: CGPoint(x: 270, y: 294))
        callout(in: context, text: "Start", from: CGPoint(x: 295, y: 134), to: CGPoint(x: 310, y: 279))
    }

    private func trigger(in context: GraphicsContext, rect: CGRect, control: GamepadControl) {
        let shape = Path(roundedRect: rect, cornerRadius: 9)
        context.fill(shape, with: .color(WineTheme.elevated))
        let amount = connected ? min(1, max(0, input.value(for: control))) : 0
        if amount > 0 {
            let fill = CGRect(x: rect.minX, y: rect.maxY - rect.height * amount, width: rect.width, height: rect.height * amount)
            var clipped = context
            clipped.clip(to: shape)
            clipped.fill(Path(fill), with: .color(WineTheme.accent))
        }
        context.stroke(shape, with: .color(WineTheme.accent.opacity(0.8)), lineWidth: 1)
    }

    private func shoulder(in context: GraphicsContext, rect: CGRect, control: GamepadControl) {
        let shape = Path(roundedRect: rect, cornerRadius: 7)
        context.fill(shape, with: .color(isActive(control) ? WineTheme.accent : WineTheme.elevated))
        context.stroke(shape, with: .color(WineTheme.muted.opacity(0.5)), lineWidth: 1)
    }

    private func stick(in context: GraphicsContext, center: CGPoint, x: Double, y: Double, control: GamepadControl) {
        let base = Path(ellipseIn: CGRect(x: center.x - 29, y: center.y - 29, width: 58, height: 58))
        context.fill(base, with: .color(WineTheme.background))
        context.stroke(base, with: .color(WineTheme.accent.opacity(0.8)), lineWidth: 2)
        let offset = CGPoint(x: center.x + min(1, max(-1, x)) * 10,
                             y: center.y - min(1, max(-1, y)) * 10)
        let cap = Path(ellipseIn: CGRect(x: offset.x - 22, y: offset.y - 22, width: 44, height: 44))
        context.fill(cap, with: .linearGradient(Gradient(colors: [WineTheme.elevated, WineTheme.background]),
                                               startPoint: CGPoint(x: offset.x, y: offset.y - 22),
                                               endPoint: CGPoint(x: offset.x, y: offset.y + 22)))
        context.stroke(cap, with: .color(isActive(control) ? WineTheme.accent : WineTheme.muted.opacity(0.6)), lineWidth: isActive(control) ? 3 : 1)
    }

    private func dpad(in context: GraphicsContext) {
        let base = Path(ellipseIn: CGRect(x: 174, y: 155, width: 62, height: 62))
        context.fill(base, with: .color(WineTheme.background))
        let pieces: [(GamepadControl, CGRect, String)] = [
            (.dpadUp, CGRect(x: 195, y: 156, width: 20, height: 23), "↑"),
            (.dpadDown, CGRect(x: 195, y: 193, width: 20, height: 23), "↓"),
            (.dpadLeft, CGRect(x: 175, y: 176, width: 23, height: 20), "←"),
            (.dpadRight, CGRect(x: 212, y: 176, width: 23, height: 20), "→")
        ]
        for (control, rect, symbol) in pieces {
            let shape = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(shape, with: .color(isActive(control) ? WineTheme.accent : WineTheme.elevated))
            context.stroke(shape, with: .color(WineTheme.muted.opacity(0.25)), lineWidth: 1)
            context.draw(Text(symbol).font(.system(size: 10)).foregroundColor(WineTheme.muted),
                         at: CGPoint(x: rect.midX, y: rect.midY))
        }
        context.fill(Path(CGRect(x: 196, y: 177, width: 18, height: 18)), with: .color(WineTheme.elevated))
    }

    private func button(in context: GraphicsContext, center: CGPoint, radius: CGFloat,
                        control: GamepadControl, color: Color, label: String) {
        let shape = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(shape, with: .color(isActive(control) ? color.opacity(0.8) : WineTheme.background))
        context.stroke(shape, with: .color(color.opacity(0.6)), lineWidth: isActive(control) ? 2 : 1)
        context.draw(Text(label).font(.system(size: radius, weight: .semibold))
            .foregroundColor(isActive(control) ? .white : color), at: center)
    }

    private func callout(in context: GraphicsContext, text: String, from: CGPoint, to: CGPoint) {
        var line = Path()
        line.move(to: from)
        if to.y > 260 {
            line.addLine(to: CGPoint(x: from.x, y: to.y - 15))
            line.addLine(to: CGPoint(x: to.x, y: to.y - 8))
        } else {
            let endX = to.x < 270 ? to.x + 31 : to.x - 31
            line.addLine(to: CGPoint(x: (from.x + endX) / 2, y: to.y))
            line.addLine(to: CGPoint(x: endX, y: to.y))
        }
        context.stroke(line, with: .color(WineTheme.accent.opacity(0.6)), lineWidth: 0.8)
        context.draw(Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(WineTheme.muted), at: to)
    }

    private func isActive(_ control: GamepadControl) -> Bool {
        connected && input.value(for: control) > 0.05
    }
}

struct GamepadStickPlot: View {
    let title: String
    let x: Double
    let y: Double
    let deadZone: Double
    let connected: Bool

    var body: some View {
        VStack(spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(WineTheme.muted)
            Canvas { context, size in
                let diameter = min(size.width, size.height) - 4
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = diameter / 2
                let outer = CGRect(x: center.x - radius, y: center.y - radius, width: diameter, height: diameter)
                context.fill(Path(ellipseIn: outer), with: .color(WineTheme.background.opacity(0.4)))
                context.stroke(Path(ellipseIn: outer), with: .color(WineTheme.accent.opacity(0.65)), lineWidth: 1)
                context.stroke(Path(ellipseIn: outer.insetBy(dx: radius / 2, dy: radius / 2)),
                               with: .color(WineTheme.muted.opacity(0.18)), lineWidth: 1)
                // The ring denotes the raw dead-zone threshold; the dot is processed draft output.
                let deadRadius = radius * deadZone
                context.fill(Path(ellipseIn: CGRect(x: center.x - deadRadius, y: center.y - deadRadius,
                                                    width: deadRadius * 2, height: deadRadius * 2)),
                             with: .color(WineTheme.accent.opacity(0.14)))
                var axes = Path()
                axes.move(to: CGPoint(x: center.x - radius, y: center.y))
                axes.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                axes.move(to: CGPoint(x: center.x, y: center.y - radius))
                axes.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                context.stroke(axes, with: .color(WineTheme.muted.opacity(0.25)), lineWidth: 1)
                if connected {
                    let point = CGPoint(x: center.x + min(1, max(-1, x)) * (radius - 5),
                                        y: center.y - min(1, max(-1, y)) * (radius - 5))
                    let dot = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                    context.addFilter(.shadow(color: WineTheme.accent.opacity(0.6), radius: 5))
                    context.fill(dot, with: .color(WineTheme.accent))
                    context.stroke(dot, with: .color(Color.pink.opacity(0.8)), lineWidth: 1)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(connected ? String(format: "X %+.2f  Y %+.2f", x, y) : "No input")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(WineTheme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(connected ? String(format: "X %.2f, Y %.2f", x, y) : "Disconnected")
    }
}
