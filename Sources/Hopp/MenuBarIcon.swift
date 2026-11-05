import AppKit

/// The menu bar icon: three stacked window outlines. The two rear windows show only their top
/// and left strokes; each far end keeps the window's outer corner curve and is cut straight
/// along the stroke's inner edge.
enum MenuBarIcon {
    // Artwork units: a 199 × 140 canvas, 148 × 87 windows, 11-unit strokes, 12-unit corner radius.
    private static let canvas = NSSize(width: 199, height: 140)
    private static let windowSize = NSSize(width: 148, height: 87)
    private static let stroke: CGFloat = 11
    private static let radius: CGFloat = 12
    /// Stroke centre-line origins, back to front, in top-left-origin coordinates.
    private static let origins = [NSPoint(x: 5.5, y: 5.5), NSPoint(x: 25.5, y: 26.5), NSPoint(x: 45.5, y: 47.5)]

    static func image(height: CGFloat = 14) -> NSImage {
        let size = NSSize(width: (height * canvas.width / canvas.height).rounded(), height: height)
        let image = NSImage(size: size, flipped: true) { bounds in
            let transform = NSAffineTransform()
            transform.scaleX(by: bounds.width / canvas.width, yBy: bounds.height / canvas.height)
            transform.concat()
            NSColor.black.setStroke()
            for (index, origin) in origins.enumerated() {
                let window = NSBezierPath(roundedRect: NSRect(origin: origin, size: windowSize),
                                          xRadius: radius, yRadius: radius)
                window.lineWidth = stroke
                NSGraphicsContext.saveGraphicsState()
                if index < origins.count - 1 { visibleRegion(of: origin).addClip() }
                window.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hopp"
        return image
    }

    /// A rear window's top band, left band and top-left corner.
    private static func visibleRegion(of origin: NSPoint) -> NSBezierPath {
        let half = stroke / 2
        let outer = NSPoint(x: origin.x - half, y: origin.y - half)
        let region = NSBezierPath(rect: NSRect(x: outer.x, y: outer.y, width: windowSize.width + stroke, height: stroke))
        region.append(NSBezierPath(rect: NSRect(x: outer.x, y: outer.y, width: stroke, height: windowSize.height + stroke)))
        region.append(NSBezierPath(rect: NSRect(x: outer.x, y: outer.y, width: radius + half, height: radius + half)))
        region.windingRule = .nonZero
        return region
    }
}
