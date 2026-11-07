import AppKit
import CoreGraphics
import Foundation

private func makeColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

private func drawIcon(in context: CGContext) {
    let center = CGPoint(x: 512, y: 512)
    let shell = CGRect(x: 97, y: 101, width: 830, height: 830)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -17), blur: 42, color: makeColor(0.02, 0.10, 0.09, alpha: 0.52))
    context.setFillColor(makeColor(0.02, 0.15, 0.15))
    context.fillEllipse(in: shell)
    context.restoreGState()

    let colors = [
        makeColor(0.12, 0.36, 0.32),
        makeColor(0.07, 0.22, 0.22),
        makeColor(0.03, 0.10, 0.11),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    context.saveGState()
    context.addEllipse(in: shell)
    context.clip()
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 290, y: 904),
        end: CGPoint(x: 723, y: 135),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    context.setStrokeColor(makeColor(0.60, 0.93, 0.83, alpha: 0.48))
    context.setLineWidth(13)
    context.strokeEllipse(in: shell.insetBy(dx: 7, dy: 7))
    context.setLineCap(.round)

    let trackRadius: CGFloat = 255
    let startAngle = CGFloat.pi * 1.2
    let endAngle = CGFloat.pi * -0.2
    context.setStrokeColor(makeColor(0.30, 0.62, 0.56, alpha: 0.55))
    context.setLineWidth(42)
    context.addArc(center: center, radius: trackRadius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    context.strokePath()

    let needleAngle = CGFloat.pi * 0.27
    context.setStrokeColor(makeColor(0.45, 0.98, 0.78))
    context.addArc(center: center, radius: trackRadius, startAngle: startAngle, endAngle: needleAngle, clockwise: true)
    context.strokePath()

    let needleEnd = CGPoint(x: center.x + 178 * cos(needleAngle), y: center.y + 178 * sin(needleAngle))
    context.setLineWidth(30)
    context.setStrokeColor(makeColor(0.93, 1, 0.97))
    context.move(to: center)
    context.addLine(to: needleEnd)
    context.strokePath()
    context.setFillColor(makeColor(0.93, 1, 0.97))
    context.fillEllipse(in: CGRect(x: center.x - 38, y: center.y - 38, width: 76, height: 76))
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let drawingScale = CGFloat(pixels) / 1024
        context.scaleBy(x: drawingScale, y: drawingScale)
        drawIcon(in: context)
        let image = NSBitmapImageRep(cgImage: context.makeImage()!)
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(size)x\(size)\(suffix).png"
        try image.representation(using: .png, properties: [:])!.write(to: outputDirectory.appendingPathComponent(filename))
    }
}
