// SPDX-License-Identifier: GPL-3.0-or-later
//
// Draws the Perekey app icon: an indigo tile with a strip of frosted glass laid
// over a word ("Стеклянная правка", DESIGN.md) and a swap arrow on the strip.
// Every size is drawn natively, not scaled, and small sizes drop the fine detail.
//
//   swift scripts/make-icon.swift <out.iconset dir>
//
// scripts/make-icon.sh wraps this and runs iconutil to produce Support/AppIcon.icns.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops as CFArray, locations: nil)!
}

func pill(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
}

func render(px: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    let small = px <= 32
    let margin: CGFloat = small ? 30 : 100

    // Tile.
    let tile = CGRect(x: margin, y: margin, width: 1024 - 2 * margin, height: 1024 - 2 * margin)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.2237, cornerHeight: tile.width * 0.2237, transform: nil)
    ctx.saveGState()
    if !small { ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x15133F, 0.45)) }
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x4644D0))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0x8E8CFF), color(0x5E5CE6), color(0x3836B8)]),
        start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    ctx.restoreGState()
    if !small {
        ctx.addPath(tilePath)
        ctx.setStrokeColor(color(0xFFFFFF, 0.35))
        ctx.setLineWidth(4)
        ctx.strokePath()
    }

    // The word under the glass: ghost bars above and below the strip.
    if !small {
        ctx.setFillColor(color(0xFFFFFF, 0.30))
        var x: CGFloat = 215
        for width: CGFloat in [210, 110, 250] {
            ctx.addPath(pill(CGRect(x: x, y: 700, width: width, height: 64)))
            x += width + 34
        }
        x = 215
        for width: CGFloat in [290, 150] {
            ctx.addPath(pill(CGRect(x: x, y: 262, width: width, height: 64)))
            x += width + 34
        }
        ctx.fillPath()
    }

    // The glass strip.
    let strip = small
        ? CGRect(x: 96, y: 330, width: 832, height: 364)
        : CGRect(x: 150, y: 390, width: 724, height: 244)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: small ? 12 : 44, color: color(0x1B1990, 0.6))
    ctx.addPath(pill(strip))
    ctx.setFillColor(color(0xFFFFFF, 0.92))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(pill(strip))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0xFFFFFF, 1), color(0xE4E3FF, 1)]),
        start: CGPoint(x: 0, y: strip.maxY), end: CGPoint(x: 0, y: strip.minY), options: [])
    ctx.restoreGState()
    if !small {
        ctx.addPath(pill(strip.insetBy(dx: 1.5, dy: 1.5)))
        ctx.setStrokeColor(color(0xFFFFFF, 0.9))
        ctx.setLineWidth(3)
        ctx.strokePath()
    }

    // Swap arrows on the strip (one bold arrow when tiny).
    ctx.setStrokeColor(color(0x4644D0))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    func arrow(from a: CGFloat, to b: CGFloat, y: CGFloat, width: CGFloat, head: CGFloat) {
        let dir: CGFloat = b > a ? 1 : -1
        ctx.setLineWidth(width)
        ctx.move(to: CGPoint(x: a, y: y))
        ctx.addLine(to: CGPoint(x: b, y: y))
        ctx.move(to: CGPoint(x: b - dir * head, y: y + head))
        ctx.addLine(to: CGPoint(x: b, y: y))
        ctx.addLine(to: CGPoint(x: b - dir * head, y: y - head))
        ctx.strokePath()
    }
    if small {
        arrow(from: 250, to: 780, y: 512, width: 120, head: 150)
    } else {
        arrow(from: 335, to: 690, y: 560, width: 34, head: 40)
        arrow(from: 689, to: 334, y: 464, width: 34, head: 40)
    }
    return ctx.makeImage()!
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.iconset>\n".utf8))
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let dest = CGImageDestinationCreateWithURL(dir.appending(path: name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, render(px: base * scale), nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(name)") }
    }
}
