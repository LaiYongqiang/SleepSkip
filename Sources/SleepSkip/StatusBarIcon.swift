import Cocoa

/// Renders and caches SleepSkip's 18×18 pt template menu bar icon.
///
/// The glyph is a minimalist wake cup with a lightning bolt: hollow outline when idle and solid
/// with a negative-space bolt cutout when active, keeping menu bar recognition distinct from the
/// system Focus moon icon with zero per-frame animation overhead.
enum StatusBarIcon {
    private static let idleImage: NSImage = render(active: false)
    private static let activeImage: NSImage = render(active: true)

    static func image(active: Bool) -> NSImage {
        active ? activeImage : idleImage
    }

    private static func render(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Cup body: slightly tapered mug centered to leave space on the right for the handle.
            let cupPath = NSBezierPath()
            cupPath.move(to: NSPoint(x: 3.2, y: 12.2))
            cupPath.line(to: NSPoint(x: 12.6, y: 12.2))
            cupPath.line(to: NSPoint(x: 12.1, y: 5.4))
            cupPath.curve(
                to: NSPoint(x: 9.7, y: 3.2),
                controlPoint1: NSPoint(x: 12.0, y: 4.0),
                controlPoint2: NSPoint(x: 11.0, y: 3.2)
            )
            cupPath.line(to: NSPoint(x: 6.1, y: 3.2))
            cupPath.curve(
                to: NSPoint(x: 3.7, y: 5.4),
                controlPoint1: NSPoint(x: 4.8, y: 3.2),
                controlPoint2: NSPoint(x: 3.8, y: 4.0)
            )
            cupPath.close()

            // Handle on the right side of the cup.
            let handlePath = NSBezierPath()
            handlePath.lineWidth = 1.45
            handlePath.lineCapStyle = .round
            handlePath.lineJoinStyle = .round
            handlePath.move(to: NSPoint(x: 12.6, y: 10.9))
            handlePath.curve(
                to: NSPoint(x: 15.2, y: 8.6),
                controlPoint1: NSPoint(x: 14.3, y: 10.9),
                controlPoint2: NSPoint(x: 15.2, y: 9.9)
            )
            handlePath.curve(
                to: NSPoint(x: 12.3, y: 6.3),
                controlPoint1: NSPoint(x: 15.2, y: 7.3),
                controlPoint2: NSPoint(x: 14.1, y: 6.3)
            )
            handlePath.stroke()

            // Subtle steam wisps above the rim when active; clean rim line when idle.
            let steamLeft = NSBezierPath()
            steamLeft.lineWidth = 1.2
            steamLeft.lineCapStyle = .round
            steamLeft.move(to: NSPoint(x: 6.2, y: 13.7))
            steamLeft.curve(
                to: NSPoint(x: 6.4, y: 15.8),
                controlPoint1: NSPoint(x: 5.6, y: 14.5),
                controlPoint2: NSPoint(x: 6.9, y: 15.0)
            )

            let steamRight = NSBezierPath()
            steamRight.lineWidth = 1.2
            steamRight.lineCapStyle = .round
            steamRight.move(to: NSPoint(x: 9.5, y: 13.7))
            steamRight.curve(
                to: NSPoint(x: 9.7, y: 15.8),
                controlPoint1: NSPoint(x: 8.9, y: 14.5),
                controlPoint2: NSPoint(x: 10.2, y: 15.0)
            )

            if active {
                steamLeft.stroke()
                steamRight.stroke()

                // Negative-space lightning bolt punched inside the filled mug via even-odd rule.
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: 8.5, y: 10.6))
                bolt.line(to: NSPoint(x: 6.2, y: 7.6))
                bolt.line(to: NSPoint(x: 7.8, y: 7.6))
                bolt.line(to: NSPoint(x: 7.3, y: 4.9))
                bolt.line(to: NSPoint(x: 9.8, y: 8.0))
                bolt.line(to: NSPoint(x: 8.1, y: 8.0))
                bolt.close()

                cupPath.append(bolt)
                cupPath.windingRule = .evenOdd
                cupPath.fill()
            } else {
                cupPath.lineWidth = 1.4
                cupPath.lineJoinStyle = .round
                cupPath.stroke()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}
