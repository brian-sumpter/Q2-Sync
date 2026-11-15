//
//  make-app-icon.swift
//  Q2-Sync › Scripts
//
//  PURPOSE
//  Draws Q2 Sync's app icon (a blue, iPod-style player with a music note)
//  at 1024×1024 and writes it as a PNG. `Scripts/make-app-icon.sh` then
//  resizes it into every size macOS needs.
//
//  USAGE
//      swift Scripts/make-app-icon.swift <output.png>
//

import AppKit

let size: CGFloat = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png")

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: an 824-point rounded square centred on the canvas,
    // leaving room for the system's drop shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    // Soft shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Blue gradient background.
    NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.62, blue: 1.00, alpha: 1),
               ending: NSColor(srgbRed: 0.04, green: 0.33, blue: 0.86, alpha: 1))!
        .draw(in: tilePath, angle: -90)

    // The player body: white, with a gentle top-to-bottom shade.
    let body = NSRect(x: 302, y: 190, width: 420, height: 644)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 78, yRadius: 78)
    NSGraphicsContext.saveGraphicsState()
    let bodyShadow = NSShadow()
    bodyShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    bodyShadow.shadowBlurRadius = 30
    bodyShadow.shadowOffset = NSSize(width: 0, height: -14)
    bodyShadow.set()
    NSColor.white.setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: .white, ending: NSColor(white: 0.90, alpha: 1))!.draw(in: bodyPath, angle: -90)

    // The screen.
    let screen = NSRect(x: 342, y: 532, width: 340, height: 256)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 30, yRadius: 30)
    NSGradient(starting: NSColor(srgbRed: 0.80, green: 0.89, blue: 1.00, alpha: 1),
               ending: NSColor(srgbRed: 0.58, green: 0.75, blue: 0.98, alpha: 1))!.draw(in: screenPath, angle: -90)

    // A music note on the screen (SF Symbol), in the icon's blue.
    let config = NSImage.SymbolConfiguration(pointSize: 150, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(srgbRed: 0.04, green: 0.33, blue: 0.86, alpha: 1)]))
    if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let noteSize = note.size
        note.draw(in: NSRect(x: screen.midX - noteSize.width / 2, y: screen.midY - noteSize.height / 2,
                             width: noteSize.width, height: noteSize.height))
    }

    // The click wheel and its centre button.
    let wheelCenter = NSPoint(x: body.midX, y: 352)
    let wheel = NSBezierPath(ovalIn: NSRect(x: wheelCenter.x - 124, y: wheelCenter.y - 124, width: 248, height: 248))
    NSGradient(starting: NSColor(white: 0.84, alpha: 1), ending: NSColor(white: 0.95, alpha: 1))!.draw(in: wheel, angle: -90)
    let button = NSBezierPath(ovalIn: NSRect(x: wheelCenter.x - 50, y: wheelCenter.y - 50, width: 100, height: 100))
    NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.62, blue: 1.00, alpha: 1),
               ending: NSColor(srgbRed: 0.04, green: 0.33, blue: 0.86, alpha: 1))!.draw(in: button, angle: -90)
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Couldn't render the icon")
}
try png.write(to: output)
print("Wrote \(output.path)")
