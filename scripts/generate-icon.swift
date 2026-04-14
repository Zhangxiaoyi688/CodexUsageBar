#!/usr/bin/env swift

import AppKit
import Foundation

let fileManager = FileManager.default
let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let assetsURL = rootURL.appendingPathComponent("Assets", isDirectory: true)
let iconsetURL = assetsURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let outputURL = assetsURL.appendingPathComponent("AppIcon.icns")

try? fileManager.removeItem(at: iconsetURL)
try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let entries: [(points: CGFloat, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

for entry in entries {
    let pixelSize = Int(entry.points) * entry.scale
    let image = drawIcon(pixelSize: pixelSize)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    rep.size = NSSize(width: entry.points, height: entry.points)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to render PNG for \(pixelSize)x\(pixelSize)")
    }

    let name = iconName(points: Int(entry.points), scale: entry.scale)
    try pngData.write(to: iconsetURL.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}

print(outputURL.path)

func iconName(points: Int, scale: Int) -> String {
    if scale == 1 {
        return "icon_\(points)x\(points).png"
    }
    return "icon_\(points)x\(points)@\(scale)x.png"
}

func drawIcon(pixelSize: Int) -> NSImage {
    let size = NSSize(width: pixelSize, height: pixelSize)
    let image = NSImage(size: size)
    image.lockFocus()

    let rect = CGRect(origin: .zero, size: size)
    NSColor.clear.setFill()
    rect.fill()

    let cornerRadius = CGFloat(pixelSize) * 0.23
    let backgroundRect = rect.insetBy(dx: CGFloat(pixelSize) * 0.03, dy: CGFloat(pixelSize) * 0.03)
    let background = NSBezierPath(roundedRect: backgroundRect, xRadius: cornerRadius, yRadius: cornerRadius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.11, alpha: 1.0),
        NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.17, alpha: 1.0),
        NSColor(calibratedRed: 0.21, green: 0.24, blue: 0.22, alpha: 1.0)
    ])!
    gradient.draw(in: background, angle: -55)

    let sheen = NSGradient(colors: [
        NSColor(calibratedRed: 0.35, green: 0.72, blue: 0.63, alpha: 0.20),
        NSColor(calibratedRed: 0.45, green: 0.64, blue: 0.80, alpha: 0.06),
        NSColor.clear
    ])!
    sheen.draw(in: background, angle: -50)

    NSColor.white.withAlphaComponent(0.06).setStroke()
    background.lineWidth = CGFloat(pixelSize) * 0.014
    background.stroke()

    if let context = NSGraphicsContext.current?.cgContext {
        drawMeter(in: context, rect: backgroundRect)
        drawBars(in: context, rect: backgroundRect)
        drawGlow(in: context, rect: backgroundRect)
    }

    image.unlockFocus()
    return image
}

func drawMeter(in context: CGContext, rect: CGRect) {
    let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.02)
    let radius = rect.width * 0.27
    let lineWidth = rect.width * 0.10

    context.saveGState()
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)

    context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.strokePath()

    let startAngle = radians(-150)
    let endAngle = startAngle + (.pi * 2 * 0.74)
    context.setStrokeColor(NSColor(calibratedRed: 0.82, green: 0.72, blue: 0.46, alpha: 1.0).cgColor)
    context.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
    context.strokePath()

    let marker = CGPoint(x: center.x + cos(endAngle) * radius, y: center.y + sin(endAngle) * radius)
    let markerSize = lineWidth * 0.34
    context.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    context.fillEllipse(in: CGRect(x: marker.x - markerSize, y: marker.y - markerSize, width: markerSize * 2, height: markerSize * 2))

    context.restoreGState()
}

func drawBars(in context: CGContext, rect: CGRect) {
    let barWidth = rect.width * 0.095
    let spacing = rect.width * 0.055
    let totalWidth = barWidth * 3 + spacing * 2
    let baseline = rect.minY + rect.height * 0.24
    let startX = rect.midX - totalWidth * 0.5

    context.saveGState()
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    context.setLineWidth(rect.width * 0.014)
    context.move(to: CGPoint(x: startX - rect.width * 0.04, y: baseline))
    context.addLine(to: CGPoint(x: startX + totalWidth + rect.width * 0.04, y: baseline))
    context.strokePath()

    let heights: [CGFloat] = [rect.height * 0.14, rect.height * 0.23, rect.height * 0.33]
    let colorPairs: [(NSColor, NSColor)] = [
        (
            NSColor(calibratedRed: 0.31, green: 0.71, blue: 0.64, alpha: 0.95),
            NSColor(calibratedRed: 0.38, green: 0.82, blue: 0.73, alpha: 1.0)
        ),
        (
            NSColor(calibratedRed: 0.44, green: 0.62, blue: 0.80, alpha: 0.95),
            NSColor(calibratedRed: 0.53, green: 0.72, blue: 0.91, alpha: 1.0)
        ),
        (
            NSColor(calibratedRed: 0.77, green: 0.68, blue: 0.42, alpha: 0.95),
            NSColor(calibratedRed: 0.88, green: 0.80, blue: 0.53, alpha: 1.0)
        )
    ]

    for index in 0..<heights.count {
        let x = startX + CGFloat(index) * (barWidth + spacing)
        let barRect = CGRect(x: x, y: baseline, width: barWidth, height: heights[index])
        let path = CGPath(roundedRect: barRect, cornerWidth: barWidth * 0.46, cornerHeight: barWidth * 0.46, transform: nil)

        context.saveGState()
        context.addPath(path)
        context.clip()

        let colors = [colorPairs[index].0.cgColor, colorPairs[index].1.cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: barRect.midX, y: barRect.minY),
            end: CGPoint(x: barRect.midX, y: barRect.maxY),
            options: []
        )
        context.restoreGState()
    }

    context.restoreGState()
}

func drawGlow(in context: CGContext, rect: CGRect) {
    let glowRect = CGRect(
        x: rect.minX + rect.width * 0.14,
        y: rect.midY + rect.height * 0.08,
        width: rect.width * 0.72,
        height: rect.height * 0.22
    )

    context.saveGState()
    context.addEllipse(in: glowRect)
    context.clip()

    let colors = [
        NSColor.white.withAlphaComponent(0.14).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawRadialGradient(
        gradient,
        startCenter: CGPoint(x: glowRect.midX, y: glowRect.midY),
        startRadius: 0,
        endCenter: CGPoint(x: glowRect.midX, y: glowRect.midY),
        endRadius: glowRect.width * 0.48,
        options: [.drawsAfterEndLocation]
    )

    context.restoreGState()
}

func radians(_ degrees: CGFloat) -> CGFloat {
    degrees * .pi / 180
}
