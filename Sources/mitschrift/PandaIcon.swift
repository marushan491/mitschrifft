import AppKit

enum PandaState {
    case ready
    case recording
    case paused
}

enum PandaIcon {
    static func menuBar(_ state: PandaState, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawGlyph(state: state, in: rect, color: .black, faceFill: nil)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.width * 0.06
            let plate = rect.insetBy(dx: inset, dy: inset)
            let radius = plate.width * 0.235

            let background = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
            let gradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.26, green: 0.42, blue: 0.78, alpha: 1),
                NSColor(calibratedRed: 0.13, green: 0.24, blue: 0.55, alpha: 1)
            ])
            gradient?.draw(in: background, angle: -90)

            let glyph = plate.insetBy(dx: plate.width * 0.14, dy: plate.width * 0.14)
            drawGlyph(state: .ready, in: glyph, color: NSColor(calibratedWhite: 0.08, alpha: 1),
                      faceFill: .white)
            return true
        }
    }

    private static func punchOut(_ path: NSBezierPath, stroke: CGFloat? = nil) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSColor.black.setStroke()
        if let stroke {
            path.lineWidth = stroke
            path.lineCapStyle = .round
            path.stroke()
        } else {
            path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawGlyph(state: PandaState, in rect: NSRect, color: NSColor, faceFill: NSColor?) {
        let s = min(rect.width, rect.height)
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: rect.minX + (cx - r) * s,
                                        y: rect.minY + (cy - r) * s,
                                        width: 2 * r * s,
                                        height: 2 * r * s))
        }
        func patch(_ cx: CGFloat) -> NSBezierPath {
            let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 0.185 * s, height: 0.215 * s))
            let anchor = point(cx, 0.465)
            var move = AffineTransform(translationByX: anchor.x, byY: anchor.y)
            move.rotate(byDegrees: cx < 0.5 ? 14 : -14)
            move.translate(x: -0.0925 * s, y: -0.1075 * s)
            path.transform(using: move)
            return path
        }

        let solid = state == .recording
        color.setFill()
        color.setStroke()

        circle(0.235, 0.795, 0.135).fill()
        circle(0.765, 0.795, 0.135).fill()

        let head = circle(0.5, 0.43, 0.365)
        if solid {
            head.fill()
        } else if let faceFill {
            faceFill.setFill()
            head.fill()
            color.setFill()
            head.lineWidth = s * 0.075
            head.stroke()
        } else {
            head.lineWidth = s * 0.075
            head.stroke()
        }

        let nose = NSBezierPath(ovalIn: NSRect(x: rect.minX + 0.44 * s,
                                               y: rect.minY + 0.25 * s,
                                               width: 0.12 * s,
                                               height: 0.085 * s))

        if solid {
            punchOut(patch(0.35))
            punchOut(patch(0.65))
            punchOut(nose)
        } else {
            patch(0.35).fill()
            patch(0.65).fill()
            nose.fill()

            if let faceFill {
                faceFill.setFill()
                circle(0.365, 0.495, 0.030).fill()
                circle(0.635, 0.495, 0.030).fill()
                color.setFill()
            }
        }

        if state == .paused {
            let slash = NSBezierPath()
            slash.move(to: point(0.13, 0.11))
            slash.line(to: point(0.87, 0.89))
            punchOut(slash, stroke: s * 0.21)
            color.setStroke()
            slash.lineWidth = s * 0.10
            slash.lineCapStyle = .round
            slash.stroke()
        }
    }
}

extension PandaIcon {
    static func glyph(_ state: PandaState, size: CGFloat, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawGlyph(state: state, in: rect, color: color, faceFill: nil)
            return true
        }
    }

    static func previewStrip(scale: CGFloat = 8) -> NSImage {
        let cell: CGFloat = 24
        let states: [PandaState] = [.ready, .recording, .paused]
        let width = cell * CGFloat(states.count)
        let height = cell * 2

        let dark = states.map { glyph($0, size: 18, color: .white) }
        let light = states.map { glyph($0, size: 18, color: .black) }

        let base = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
            NSRect(x: 0, y: cell, width: width, height: cell).fill()
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: width, height: cell).fill()

            for index in states.indices {
                let x = CGFloat(index) * cell + (cell - 18) / 2
                dark[index].draw(in: NSRect(x: x, y: cell + (cell - 18) / 2, width: 18, height: 18))
                light[index].draw(in: NSRect(x: x, y: (cell - 18) / 2, width: 18, height: 18))
            }
            return true
        }

        let big = NSImage(size: NSSize(width: width * scale, height: height * scale))
        big.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        base.draw(in: NSRect(origin: .zero, size: big.size))
        big.unlockFocus()
        return big
    }

    static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { return }
        try data.write(to: url)
    }
}
