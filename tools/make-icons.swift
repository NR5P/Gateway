// Draws the Gateway app icon: a radio tower with radiating arcs, light teal on dark teal.
//
//   swift tools/make-icons.swift Gateway/Assets.xcassets/AppIcon.appiconset
//
// Writes icon-ios-1024.png (full bleed; iOS applies the mask) and the macOS set
// (icon-mac-<size>.png, a rounded tile with margins per the macOS grid).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let light = CGColor(red: 0x5D / 255.0, green: 0xCA / 255.0, blue: 0xA5 / 255.0, alpha: 1)
let dark = CGColor(red: 0x04 / 255.0, green: 0x34 / 255.0, blue: 0x2C / 255.0, alpha: 1)

/// Draws the artwork into a 1024-unit square `rect`.
func artwork(_ ctx: CGContext, in rect: CGRect) {
    let s = rect.width / 1024
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
    ctx.setStrokeColor(light)
    ctx.setFillColor(light)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Lattice tower: two legs, cross bracing, base. y grows upwards.
    let top = p(512, 640), bl = p(372, 170), br = p(652, 170)
    ctx.setLineWidth(34 * s)
    ctx.move(to: bl); ctx.addLine(to: top); ctx.addLine(to: br)
    ctx.strokePath()
    ctx.setLineWidth(22 * s)
    let levels: [CGFloat] = [170, 300, 420, 530]
    func leg(_ y: CGFloat) -> (CGPoint, CGPoint) {
        let t = (y - 170) / (640 - 170)
        let half = 140 * (1 - t)
        return (p(512 - half, y), p(512 + half, y))
    }
    for (i, y) in levels.enumerated() {
        let (l, r) = leg(y)
        ctx.move(to: l); ctx.addLine(to: r)
        if i + 1 < levels.count {
            let (l2, r2) = leg(levels[i + 1])
            ctx.move(to: l); ctx.addLine(to: r2)
            ctx.move(to: r); ctx.addLine(to: l2)
        }
    }
    ctx.strokePath()
    // Beacon at the top.
    let c = p(512, 690)
    ctx.fillEllipse(in: CGRect(x: c.x - 42 * s, y: c.y - 42 * s, width: 84 * s, height: 84 * s))
    // Radiating arcs, both sides.
    for (i, r) in [CGFloat(120), 200, 280].enumerated() {
        ctx.setLineWidth(CGFloat(38 - i * 5) * s)
        ctx.addArc(center: c, radius: r * s, startAngle: -.pi * 0.22, endAngle: .pi * 0.22, clockwise: false)
        ctx.strokePath()
        ctx.addArc(center: c, radius: r * s, startAngle: .pi * 0.78, endAngle: .pi * 1.22, clockwise: false)
        ctx.strokePath()
    }
}

func render(_ size: Int, mac: Bool) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let full = CGRect(x: 0, y: 0, width: size, height: size)
    if mac {
        // macOS: 824/1024 tile, corner radius ~185/1024, soft shadow.
        let inset = CGFloat(size) * 100 / 1024
        let tile = full.insetBy(dx: inset, dy: inset)
        let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(size) * 0.01), blur: CGFloat(size) * 0.02,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(dark)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.clip()
        artwork(ctx, in: tile)
    } else {
        ctx.setFillColor(dark)
        ctx.fill(full)
        artwork(ctx, in: full.insetBy(dx: CGFloat(size) * 0.04, dy: CGFloat(size) * 0.04))
    }
    return ctx.makeImage()!
}

func write(_ img: CGImage, _ url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
write(render(1024, mac: false), dir.appendingPathComponent("icon-ios-1024.png"))
var images: [String] = [#"    { "filename" : "icon-ios-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }"#]
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = "icon-mac-\(px).png"
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            write(render(px, mac: true), dir.appendingPathComponent(name))
        }
        images.append(#"    { "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(pt)x\#(pt)" }"#)
    }
}
let json = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! json.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
