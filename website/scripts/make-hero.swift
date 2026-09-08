// Renders a 16:9 hero image in Transcriber's own design language: the dark gradient from the
// app icon, the recording pill from the menu bar, and the floating transcript bar.
// Usage: swift website/scripts/make-hero.swift <out.png> "<Speaker: line>" "<Speaker: line>" "<Speaker: line>" [timer]
// Lines are "Name: text". The last line is drawn brighter, as the one being transcribed right now.
import AppKit

let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: make-hero.swift out.png \"Name: line\" ... [mm:ss]"); exit(2) }
let out = a[1]
var lines = Array(a[2...])
var timer = "12:47"
if let last = lines.last, last.range(of: #"^\d\d:\d\d$"#, options: .regularExpression) != nil { timer = last; lines.removeLast() }

let W: CGFloat = 1600, H: CGFloat = 900
let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a).cgColor }
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// Background: the icon gradient (#1e2028 -> #0a0b0f)
let g = CGGradient(colorsSpace: sRGB, colors: [rgb(0x1e, 0x20, 0x28), rgb(0x0a, 0x0b, 0x0f)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
// a soft red glow behind the pill, like the dot's pulse
let glow = CGGradient(colorsSpace: sRGB, colors: [rgb(255, 0x3b, 0x30, 0.16), rgb(255, 0x3b, 0x30, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W * 0.5, y: H * 0.56), startRadius: 0, endCenter: CGPoint(x: W * 0.5, y: H * 0.56), endRadius: 560, options: [])

// Menu bar strip
let barH: CGFloat = 64
let menuRect = CGRect(x: 0, y: H - barH, width: W, height: barH)
ctx.setFillColor(rgb(255, 255, 255, 0.06)); ctx.fill(menuRect)
ctx.setFillColor(rgb(255, 255, 255, 0.10)); ctx.fill(CGRect(x: 0, y: H - barH, width: W, height: 1.5))
// a few faint menu bar glyph placeholders on the right
var gx = W - 70
for w in [22, 26, 30, 44] as [CGFloat] {
    ctx.setFillColor(rgb(255, 255, 255, 0.30))
    ctx.addPath(rounded(CGRect(x: gx - w, y: H - barH / 2 - 7, width: w, height: 14), 4)); ctx.fillPath()
    gx -= w + 22
}
// The recording pill, sitting in the menu bar
let pillW: CGFloat = 250, pillH: CGFloat = 40
let pill = CGRect(x: gx - 30 - pillW, y: H - barH / 2 - pillH / 2, width: pillW, height: pillH)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: rgb(0, 0, 0, 0.5))
ctx.addPath(rounded(pill, pillH / 2)); ctx.setFillColor(rgb(0, 0, 0, 0.92)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(rounded(pill.insetBy(dx: 0.75, dy: 0.75), pillH / 2)); ctx.setStrokeColor(rgb(255, 255, 255, 0.2)); ctx.setLineWidth(1.5); ctx.strokePath()
let dot: CGFloat = 12
let dotRect = CGRect(x: pill.minX + 16, y: pill.midY - dot / 2, width: dot, height: dot)
ctx.setFillColor(rgb(255, 0x3b, 0x30)); ctx.fillEllipse(in: dotRect)
let levels: [CGFloat] = [0.3, 0.7, 1, 0.55, 0.85, 0.4, 0.95, 0.6, 0.35, 0.5, 0.8, 0.45]
let waveH: CGFloat = 20, bw: CGFloat = 4, bgap: CGFloat = 3.5
var x = dotRect.maxX + 14
ctx.setFillColor(rgb(255, 255, 255, 0.9))
for l in levels { let h = max(2, l * waveH); ctx.addPath(rounded(CGRect(x: x, y: pill.midY - h / 2, width: bw, height: h), bw / 2)); ctx.fillPath(); x += bw + bgap }
let timerAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
let tsz = (timer as NSString).size(withAttributes: timerAttrs)
(timer as NSString).draw(at: CGPoint(x: pill.maxX - 18 - tsz.width, y: pill.midY - tsz.height / 2), withAttributes: timerAttrs)

// Floating transcript bar below the menu bar, centred (the real one is 420 pt wide, 1 to 3 lines)
let fbW: CGFloat = 1120, lineH: CGFloat = 46, pad: CGFloat = 26
let fbH = pad * 2 + lineH * CGFloat(lines.count)
let fb = CGRect(x: (W - fbW) / 2, y: H * 0.56 - fbH / 2, width: fbW, height: fbH)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: rgb(0, 0, 0, 0.55))
ctx.addPath(rounded(fb, 22)); ctx.setFillColor(rgb(0x14, 0x15, 0x1b, 0.96)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(rounded(fb.insetBy(dx: 0.75, dy: 0.75), 22)); ctx.setStrokeColor(rgb(255, 255, 255, 0.14)); ctx.setLineWidth(1.5); ctx.strokePath()
// red indicator + tiny waveform at the left edge, like the app
let ind = CGRect(x: fb.minX + 28, y: fb.midY - 5, width: 10, height: 10)
ctx.setFillColor(rgb(255, 0x3b, 0x30)); ctx.fillEllipse(in: ind)
let textX = fb.minX + 62
let nameFont = NSFont.systemFont(ofSize: 27, weight: .semibold), textFont = NSFont.systemFont(ofSize: 27)
for (i, raw) in lines.enumerated() {
    let isLast = i == lines.count - 1
    let alpha: CGFloat = isLast ? 0.95 : (i == lines.count - 2 ? 0.7 : 0.45)
    let y = fb.maxY - pad - lineH * CGFloat(i + 1) + (lineH - 32) / 2
    let parts = raw.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
    let s = NSMutableAttributedString()
    if parts.count == 2 {
        s.append(NSAttributedString(string: parts[0] + "  ", attributes: [.font: nameFont, .foregroundColor: NSColor.white.withAlphaComponent(alpha)]))
        s.append(NSAttributedString(string: parts[1], attributes: [.font: textFont, .foregroundColor: NSColor.white.withAlphaComponent(alpha)]))
    } else {
        s.append(NSAttributedString(string: raw, attributes: [.font: textFont, .foregroundColor: NSColor.white.withAlphaComponent(alpha)]))
    }
    // clip to the bar width
    let maxW = fb.maxX - 28 - textX
    var str = s
    while str.size().width > maxW && str.length > 4 { str = NSMutableAttributedString(attributedString: str.attributedSubstring(from: NSRange(location: 0, length: str.length - 2))); str.append(NSAttributedString(string: "…", attributes: [.font: textFont, .foregroundColor: NSColor.white.withAlphaComponent(alpha)])) }
    str.draw(at: CGPoint(x: textX, y: y))
}

// Caption at the bottom: what the picture shows, in the app's own words
let capAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
let cap = "Recorded on your Mac. Nobody joins the call."
let csz = (cap as NSString).size(withAttributes: capAttrs)
(cap as NSString).draw(at: CGPoint(x: (W - csz.width) / 2, y: fb.minY - 64 - csz.height), withAttributes: capAttrs)

let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.32)]
let sub = "Zoom  ·  Teams  ·  Meet  ·  FaceTime  ·  WhatsApp  ·  any app that plays audio"
let ssz = (sub as NSString).size(withAttributes: subAttrs)
(sub as NSString).draw(at: CGPoint(x: (W - ssz.width) / 2, y: fb.minY - 64 - csz.height - 16 - ssz.height), withAttributes: subAttrs)

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
