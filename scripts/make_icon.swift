#!/usr/bin/env swift
//
// Renders the app icon (a clay-orange squircle with the burst mark) into an
// .iconset. Vector-drawn at every size, so no source artwork is checked in.
//
//   swift scripts/make_icon.swift [output-iconset-dir]
//

import AppKit
import Foundation

// MARK: - Geometry

/// Stacked session cards, back to front: (xOffset, yOffset, alpha).
/// Equal sizes offset on a diagonal, so each card stays visible behind the next.
/// Mirrors StackMark.swift.
let cards: [(CGFloat, CGFloat, CGFloat)] = [
    ( 0.105,  0.105, 0.45),
    ( 0.052,  0.052, 0.70),
    ( 0.000,  0.000, 1.00),
]

/// macOS Big Sur icon grid: artwork occupies ~80% of the canvas, corner radius
/// is ~22.37% of the *artwork* width.
let artworkInset: CGFloat = 0.10
let cornerRatio: CGFloat = 0.2237

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let inset = size * artworkInset
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plate.width * cornerRatio
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    // Clay gradient, light at top-left
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    // Indigo → violet. Deliberately not any agent vendor's colour.
    let colors = [
        NSColor(srgbRed: 0.42, green: 0.40, blue: 0.94, alpha: 1).cgColor,
        NSColor(srgbRed: 0.29, green: 0.25, blue: 0.71, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.maxX, y: plate.minY),
            options: []
        )
    }
    context.restoreGState()

    // Hairline rim for definition on light backgrounds
    context.saveGState()
    context.addPath(platePath)
    context.setStrokeColor(NSColor(white: 1, alpha: 0.22).cgColor)
    context.setLineWidth(max(1, size * 0.006))
    context.strokePath()
    context.restoreGState()

    // Stacked session cards, drawn back to front and nudged along a diagonal so
    // the ones behind stay visible.
    //
    // Below ~40px three cards with sub-pixel offsets smear into one blob, so the
    // small sizes drop to two cards with a wider throw and a thicker gap.
    let isSmall = size <= 40
    let visibleCards = isSmall ? Array(cards.suffix(2)) : cards
    let offsetScale: CGFloat = isSmall ? 1.7 : 1.0
    let gapWidth = max(isSmall ? 1.5 : 2.0, plate.width * 0.030)

    let cardWidth = plate.width * (isSmall ? 0.46 : 0.50)
    let cardHeight = plate.height * (isSmall ? 0.30 : 0.27)
    let cardRadius = cardHeight * 0.28
    let spread = CGPoint(x: -plate.width * 0.055, y: -plate.height * 0.055)

    for (dxBase, dyBase, alpha) in visibleCards {
        let dx = dxBase * offsetScale
        let dy = dyBase * offsetScale
        let rect = CGRect(
            x: plate.midX - cardWidth / 2 + plate.width * dx + spread.x,
            y: plate.midY - cardHeight / 2 - plate.height * dy - spread.y,
            width: cardWidth,
            height: cardHeight
        )
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cardRadius, cornerHeight: cardRadius,
            transform: nil
        )
        // Punch a gap around each card so the one in front reads as separate.
        context.setBlendMode(.copy)
        context.addPath(path.copy(
            strokingWithWidth: gapWidth,
            lineCap: .round, lineJoin: .round, miterLimit: 10
        ))
        context.setFillColor(NSColor.clear.cgColor)
        context.fillPath()

        context.setBlendMode(.normal)
        context.addPath(path)
        context.setFillColor(NSColor(white: 1, alpha: alpha).cgColor)
        context.fillPath()
    }

    return image
}

// MARK: - Output

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }

    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .sourceOver, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "assets/AppIcon.iconset"
let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

// (base point size, scale)
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

for (base, scale) in variants {
    let pixels = base * scale
    let name = scale == 1
        ? "icon_\(base)x\(base).png"
        : "icon_\(base)x\(base)@2x.png"
    let image = drawIcon(size: CGFloat(pixels))
    try writePNG(image, pixels: pixels, to: outputURL.appendingPathComponent(name))
    print("  \(name)  \(pixels)x\(pixels)")
}

print("iconset written to \(outputURL.path)")
