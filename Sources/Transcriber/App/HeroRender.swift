import AppKit
import SwiftUI

/// Renders marketing images from the real UI code: the menu bar pill (`PillView`) and the
/// floating transcript bar (`FloatingBarView`) with fake state, composed on the light
/// background of the landing page (the bar itself is always dark, so it stands out). Used for blog hero images so they look exactly like the app.
///
///   Transcriber --render-hero out.png [--timer 12:34] [--caption "text"] [--sub "text"] "Anna: line" "Me: line" ...
///
/// Lines are "Speaker: text". The last line is the one being transcribed right now.
enum HeroRender {
    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        var args = Array(arguments.dropFirst())
        guard let i = args.firstIndex(of: "--render-hero"), i + 1 < args.count else {
            FileHandle.standardError.write("usage: Transcriber --render-hero out.png [--timer mm:ss] [--caption text] [--sub text] \"Name: line\" ...\n".data(using: .utf8)!)
            return 2
        }
        args.remove(at: i)
        let out = args.remove(at: i)
        var timer = "12:47", caption = "Recorded on your Mac. Nobody joins the call.", sub = "Zoom  ·  Teams  ·  Meet  ·  FaceTime  ·  WhatsApp  ·  any app that plays audio"
        func take(_ flag: String, into: inout String) {
            if let j = args.firstIndex(of: flag), j + 1 < args.count { into = args[j + 1]; args.removeSubrange(j...j + 1) }
        }
        take("--timer", into: &timer); take("--caption", into: &caption); take("--sub", into: &sub)
        let lines = args

        // Fake state: recording for `timer`, a live waveform, the given lines as final transcript lines.
        let state = AppState()
        let settings = AppSettings.shared
        let parts = timer.split(separator: ":").compactMap { Int($0) }
        let elapsed = TimeInterval((parts.count == 2 ? parts[0] * 60 + parts[1] : 0))
        state.phase = .recording
        state.recordingStartedAt = Date().addingTimeInterval(-elapsed)
        state.levelHistory = [0.30, 0.70, 1.0, 0.55, 0.85, 0.40, 0.95, 0.60, 0.35, 0.50, 0.80, 0.45,
                              0.30, 0.70, 1.0, 0.55, 0.85, 0.40, 0.95, 0.60, 0.35, 0.50, 0.80, 0.45]
        var t: TimeInterval = 0
        state.liveLines = lines.map { raw in
            let p = raw.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let speaker = p.count == 2 ? p[0] : "Speaker"
            let text = p.count == 2 ? p[1] : raw
            let channel: Channel? = speaker.lowercased() == settings.myName.lowercased() || speaker.lowercased() == "me" ? .me : .them
            defer { t += 6 }
            return TranscriptLine(channel: channel, speaker: speaker, text: text, start: t)
        }
        let model = FloatingBarModel()
        model.animated = false
        model.update(state: state, settings: settings)

        // Render both views from the real code at a fixed scale.
        let scale: CGFloat = 5
        let bar = FloatingBarView(state: state, settings: settings, model: model)
        let pill = PillView(state: state).environment(\.colorScheme, .light)
        guard let barImg = render(bar, scale: scale), let pillImg = render(pill, scale: scale) else {
            FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
            return 1
        }

        // Compose: light gradient (landing page), a menu bar strip with the pill at the right, the bar under it.
        let W: CGFloat = 3200, H: CGFloat = 1800
        let img = NSImage(size: NSSize(width: W, height: H))
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return 1 }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a).cgColor }
        let g = CGGradient(colorsSpace: sRGB, colors: [rgb(0xf4, 0xf5, 0xf8), rgb(0xe3, 0xe6, 0xec)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

        let menuH = 24 * scale
        ctx.setFillColor(rgb(255, 255, 255, 0.55)); ctx.fill(CGRect(x: 0, y: H - menuH, width: W, height: menuH))
        ctx.setFillColor(rgb(0, 0, 0, 0.10)); ctx.fill(CGRect(x: 0, y: H - menuH, width: W, height: 1.5 * scale / 2))
        // faint placeholders for other menu bar items to the right of the pill
        var gx = W - 20 * scale
        for w in [6, 7, 8, 11] as [CGFloat] {
            let r = CGRect(x: gx - w * scale, y: H - menuH / 2 - 2 * scale, width: w * scale, height: 4 * scale)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: scale, cornerHeight: scale, transform: nil)); ctx.setFillColor(rgb(0x17, 0x19, 0x1f, 0.35)); ctx.fillPath()
            gx -= (w + 7) * scale
        }
        let pillSize = CGSize(width: CGFloat(pillImg.width), height: CGFloat(pillImg.height))
        ctx.draw(pillImg, in: CGRect(x: gx - 8 * scale - pillSize.width, y: H - menuH / 2 - pillSize.height / 2, width: pillSize.width, height: pillSize.height))

        let barSize = CGSize(width: CGFloat(barImg.width), height: CGFloat(barImg.height))
        let barRect = CGRect(x: (W - barSize.width) / 2, y: H - menuH - 8 * scale - barSize.height, width: barSize.width, height: barSize.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale / 2), blur: 24 * scale / 2, color: rgb(0, 0, 0, 0.35))
        ctx.draw(barImg, in: barRect)
        ctx.restoreGState()

        if !caption.isEmpty {
            let capAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17 * scale, weight: .medium), .foregroundColor: NSColor(srgbRed: 0x17/255, green: 0x19/255, blue: 0x1f/255, alpha: 1)]
            let csz = (caption as NSString).size(withAttributes: capAttrs)
            (caption as NSString).draw(at: CGPoint(x: (W - csz.width) / 2, y: H * 0.42), withAttributes: capAttrs)
            if !sub.isEmpty {
                let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12 * scale), .foregroundColor: NSColor(srgbRed: 0x76/255, green: 0x7b/255, blue: 0x8a/255, alpha: 1)]
                let ssz = (sub as NSString).size(withAttributes: subAttrs)
                (sub as NSString).draw(at: CGPoint(x: (W - ssz.width) / 2, y: H * 0.42 - 10 * scale - ssz.height), withAttributes: subAttrs)
            }
        }
        img.unlockFocus()

        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do { try png.write(to: URL(fileURLWithPath: out)) } catch { FileHandle.standardError.write("\(error)\n".data(using: .utf8)!); return 1 }
        print("wrote \(out) (bar \(Int(barSize.width / scale))x\(Int(barSize.height / scale)) pt, \(lines.count) lines)")
        return 0
    }

    @MainActor
    private static func render<V: View>(_ view: V, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }
}
