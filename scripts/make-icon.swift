// Renders the Transcriber app icon (design "4 – bar plus transcript lines") to PNG.
// Usage: swift scripts/make-icon.swift <output.png> [size]
import AppKit
import CoreImage

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let S = CGFloat(size)
let k = S / 1024

let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// macOS icon grid: the shape fills ~824/1024 with transparent margin around it.
let inset = 100 * k
let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let radius = rect.width * 0.2237
let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 40 * k, color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

// Background gradient (#1e2028 → #0a0b0f, 160°)
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let colors = [NSColor(srgbRed: 0x1e/255, green: 0x20/255, blue: 0x28/255, alpha: 1).cgColor,
              NSColor(srgbRed: 0x0a/255, green: 0x0b/255, blue: 0x0f/255, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// top highlight line
ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 1.5 * k, width: rect.width, height: 1.5 * k))
ctx.restoreGState()

// Content group (matches the mockup at 200 px, scaled by rect.width / 200)
let u = rect.width / 200
let cx = rect.midX
let barW = 156 * u, barH = 56 * u
let line1W = 132 * u, line2W = 100 * u, lineH = 9 * u
let gap = 14 * u
let totalH = barH + gap + lineH + gap + lineH
let top = rect.midY + totalH / 2 - 4 * u   // margin-top 4 in the mockup shifts the group down

// Pill
let barRect = CGRect(x: cx - barW / 2, y: top - barH, width: barW, height: barH)
let pill = CGPath(roundedRect: barRect, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)
ctx.addPath(pill); ctx.setFillColor(NSColor.black.withAlphaComponent(0.92).cgColor); ctx.fillPath()
ctx.addPath(CGPath(roundedRect: barRect.insetBy(dx: 1 * u, dy: 1 * u), cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.2).cgColor); ctx.setLineWidth(2 * u); ctx.strokePath()

// Dot
let dot = 16 * u
let dotRect = CGRect(x: barRect.minX + 20 * u, y: barRect.midY - dot / 2, width: dot, height: dot)
ctx.setFillColor(NSColor(srgbRed: 1, green: 0x3b/255, blue: 0x30/255, alpha: 1).cgColor)
ctx.fillEllipse(in: dotRect)

// Waveform: 10 bars, 84 wide, 28 high, gap 4
let levels: [CGFloat] = [0.3, 0.7, 1, 0.55, 0.85, 0.4, 0.95, 0.6, 0.35, 0.5]
let waveW = 84 * u, waveH = 28 * u, bgap = 4 * u
let bw = (waveW - bgap * 9) / 10
var x = dotRect.maxX + 14 * u
ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
for l in levels {
    let h = max(2 * u, l * waveH)
    let r = CGRect(x: x, y: barRect.midY - h / 2, width: bw, height: h)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil)); ctx.fillPath()   // fully rounded ends, like the pill
    x += bw + bgap
}

// Transcript lines
let l1 = CGRect(x: cx - line1W / 2, y: barRect.minY - gap - lineH, width: line1W, height: lineH)
ctx.addPath(CGPath(roundedRect: l1, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
ctx.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor); ctx.fillPath()

// Second line blurred (rendered via CIFilter into the context)
let l2 = CGRect(x: cx - line2W / 2, y: l1.minY - gap - lineH, width: line2W, height: lineH)
let pad = 12 * u
let blurImg = NSImage(size: NSSize(width: l2.width + 2 * pad, height: l2.height + 2 * pad))
blurImg.lockFocus()
if let c2 = NSGraphicsContext.current?.cgContext {
    c2.addPath(CGPath(roundedRect: CGRect(x: pad, y: pad, width: l2.width, height: l2.height), cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
    c2.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor); c2.fillPath()
}
blurImg.unlockFocus()
if let tiff = blurImg.tiffRepresentation, let ci = CIImage(data: tiff) {
    let f = CIFilter(name: "CIGaussianBlur")!
    f.setValue(ci, forKey: kCIInputImageKey); f.setValue(2 * u, forKey: kCIInputRadiusKey)
    if let outCI = f.outputImage?.cropped(to: ci.extent) {
        let rep = NSCIImageRep(ciImage: outCI)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        img.draw(in: CGRect(x: l2.minX - pad, y: l2.minY - pad, width: l2.width + 2 * pad, height: l2.height + 2 * pad))
    }
}

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(size)px)")
