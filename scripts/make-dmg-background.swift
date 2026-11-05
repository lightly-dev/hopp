// Draws the DMG installer window background.
//
//   swift scripts/make-dmg-background.swift
//
// Writes assets/dmg-background.png (600×380) and assets/dmg-background@2x.png
// (1200×760). The geometry must match the icon positions in build-dmg.sh:
// Hopp.app centred at (150, 180), Applications at (450, 180), window 600×380.
import AppKit

let width: CGFloat = 600
let height: CGFloat = 380
let iconCentreY: CGFloat = 180 // from the top, as Finder measures it

func render(scale: CGFloat, to path: String) throws {
    let pixelsWide = Int(width * scale)
    let pixelsHigh = Int(height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw NSError(domain: "dmg-background", code: 1) }
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Quiet vertical gradient, near-white to a faint cool grey.
    let top = NSColor(srgbRed: 0.985, green: 0.987, blue: 0.992, alpha: 1)
    let bottom = NSColor(srgbRed: 0.930, green: 0.937, blue: 0.950, alpha: 1)
    NSGradient(starting: bottom, ending: top)!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    // Arrow between the two icons (AppKit's origin is bottom-left).
    let y = height - iconCentreY
    let arrowColor = NSColor(srgbRed: 0.55, green: 0.58, blue: 0.63, alpha: 1)
    arrowColor.setStroke()
    let shaft = NSBezierPath()
    shaft.lineWidth = 4
    shaft.lineCapStyle = .round
    shaft.lineJoinStyle = .round
    shaft.move(to: NSPoint(x: 252, y: y))
    shaft.line(to: NSPoint(x: 344, y: y))
    shaft.stroke()
    let head = NSBezierPath()
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: NSPoint(x: 330, y: y + 14))
    head.line(to: NSPoint(x: 348, y: y))
    head.line(to: NSPoint(x: 330, y: y - 14))
    head.stroke()

    // Caption under the arrow.
    let caption = "Drag to Applications" as NSString
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.50, green: 0.53, blue: 0.58, alpha: 1),
        .paragraphStyle: paragraph,
    ]
    caption.draw(in: NSRect(x: 200, y: y - 40, width: 200, height: 18), withAttributes: attributes)

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "dmg-background", code: 2)
    }
    try png.write(to: URL(fileURLWithPath: path))
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
try render(scale: 1, to: root.appendingPathComponent("assets/dmg-background.png").path)
try render(scale: 2, to: root.appendingPathComponent("assets/dmg-background@2x.png").path)
