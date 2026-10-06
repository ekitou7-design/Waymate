#!/usr/bin/env swift
// Run from repository root: swift scripts/ios/generate_waymate_brand.swift
// Native CoreGraphics rasterization at each final size; no upscaled bitmap input.
import AppKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brand = root.appendingPathComponent("assets/brand/waymate")
let catalog = root.appendingPathComponent("platforms/ios/App/Assets.xcassets")
try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
let white = NSColor(srgbRed: 243/255, green: 244/255, blue: 239/255, alpha: 1).cgColor
let black = NSColor(srgbRed: 5/255, green: 6/255, blue: 7/255, alpha: 1).cgColor
// Two equal-width companion routes, rising endpoints indicate forward direction.
let routes: [[CGPoint]] = [
    [CGPoint(x: 12, y: 30), CGPoint(x: 28, y: 74), CGPoint(x: 46, y: 20)],
    [CGPoint(x: 54, y: 30), CGPoint(x: 70, y: 74), CGPoint(x: 88, y: 20)]
]
let mark = CGMutablePath()
for route in routes { mark.move(to: route[0]); route.dropFirst().forEach { mark.addLine(to: $0) } }
let svgMark = "<path d=\"M12 30 L28 74 L46 20 M54 30 L70 74 L88 20\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"8\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
func write(_ name: String, _ string: String) throws {
    try string.write(to: brand.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
try write("waymate-mark.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\" color=\"#F3F4EF\">\(svgMark)</svg>\n")
try write("waymate-app-icon.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\"><rect width=\"1024\" height=\"1024\" fill=\"#050607\"/><g transform=\"translate(102.4 102.4) scale(8.192)\" color=\"#F3F4EF\">\(svgMark)</g></svg>\n")
func png(_ url: URL, size: Int, opaque: Bool, inset: CGFloat = 0) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
    if opaque { context.setFillColor(black); context.fill(CGRect(x: 0, y: 0, width: size, height: size)) }
    context.translateBy(x: inset, y: CGFloat(size) - inset)
    let scale = (CGFloat(size) - inset * 2) / 100
    context.scaleBy(x: scale, y: -scale)
    context.setStrokeColor(white); context.setLineWidth(8)
    context.setLineCap(.round); context.setLineJoin(.round)
    context.addPath(mark); context.strokePath()
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
try png(catalog.appendingPathComponent("AppIcon.appiconset/Waymate-AppIcon.png"), size: 1024, opaque: true, inset: 102.4)
for (scale, suffix) in [(1, ""), (2, "@2x"), (3, "@3x")] {
    try png(catalog.appendingPathComponent("LaunchLogo.imageset/Waymate-LaunchLogo\(suffix).png"), size: 120 * scale, opaque: false)
}
for size in [24, 32, 256] { try png(brand.appendingPathComponent("waymate-mark-\(size).png"), size: size, opaque: false) }
// Outline a restrained system sans-serif wordmark so SVG consumers need no font.
let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 64, nil)
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "waymate", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
let letters = CGMutablePath()
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
    for i in 0..<count {
        if let path = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
            letters.addPath(path, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
        }
    }
}
let bounds = letters.boundingBoxOfPath
var commands = ""
letters.applyWithBlock { pointer in
    let e = pointer.pointee
    func point(_ i: Int) -> String { "\(e.points[i].x) \(e.points[i].y)" }
    switch e.type {
    case .moveToPoint: commands += "M\(point(0)) "
    case .addLineToPoint: commands += "L\(point(0)) "
    case .addQuadCurveToPoint: commands += "Q\(point(0)) \(point(1)) "
    case .addCurveToPoint: commands += "C\(point(0)) \(point(1)) \(point(2)) "
    case .closeSubpath: commands += "Z "
    @unknown default: break
    }
}
let textPath = "<path transform=\"translate(\(-bounds.minX) \(bounds.maxY)) scale(1 -1)\" d=\"\(commands)\" fill=\"currentColor\"/>"
try write("waymate-wordmark.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(bounds.width) \(bounds.height)\" color=\"#F3F4EF\">\(textPath)</svg>\n")
try write("waymate-lockup.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(120 + bounds.width) 100\" color=\"#F3F4EF\">\(svgMark)<g transform=\"translate(120 \((100-bounds.height)/2))\">\(textPath)</g></svg>\n")
print("Generated Waymate vector assets, native-size PNGs, AppIcon and LaunchLogo.")
// Review sheet: inspect the actual small rasters alongside the icon and wordmark.
let sheet = CGContext(data: nil, width: 1000, height: 500, bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
sheet.setFillColor(black); sheet.fill(CGRect(x: 0, y: 0, width: 1000, height: 500))
let icon = NSImage(contentsOf: catalog.appendingPathComponent("AppIcon.appiconset/Waymate-AppIcon.png"))!
sheet.draw(icon.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: CGRect(x: 20, y: 100, width: 350, height: 350))
sheet.saveGState()
sheet.translateBy(x: 430 - bounds.minX, y: 340 - bounds.minY)
sheet.setFillColor(white); sheet.addPath(letters); sheet.fillPath()
sheet.restoreGState()
for (size, x) in [(24, 440), (32, 510), (256, 600)] {
    let image = NSImage(contentsOf: brand.appendingPathComponent("waymate-mark-\(size).png"))!
    let side = size == 256 ? 120 : size
    sheet.draw(image.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: CGRect(x: x, y: 220, width: side, height: side))
}
for (i, value) in [0x050607, 0xF3F4EF, 0xB8EDF5, 0x303539, 0x42474B, 0x69D494, 0xE6C84F, 0xFF4B43].enumerated() {
    sheet.setFillColor(NSColor(srgbRed: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255, blue: CGFloat(value & 255)/255, alpha: 1).cgColor)
    sheet.fill(CGRect(x: 430 + i * 64, y: 100, width: 52, height: 52))
}
try NSBitmapImageRep(cgImage: sheet.makeImage()!).representation(using: .png, properties: [:])!.write(to: brand.appendingPathComponent("brand-preview.png"))
