import AppKit

/// Topic backdrops for blog hero images. The app's real UI (menu bar pill + floating transcript
/// bar) is always drawn on top by `HeroRender`; a scene only paints what is *behind* it, so every
/// hero still looks unmistakably like the app while the setting changes per post.
///
/// Scenes are chosen with `--scene <name>` (from `hero.json`'s `scene` field). Unknown or missing
/// falls back to `.plain` — the original clean-gradient look.
enum HeroScene: String {
    case plain          // original: just the light gradient, big centred caption
    case zoom           // a fictional video call, Zoom-blue chrome
    case teams          // a fictional video call, Teams-purple chrome
    case meet           // a fictional video call, Meet chrome
    case facetime       // a FaceTime-style call: one big tile + a small self tile

    init(name: String) { self = HeroScene(rawValue: name.lowercased()) ?? .plain }

    var isMeeting: Bool { self != .plain }
}

/// One tile in a call: a person with initials and a seeded avatar colour.
struct HeroParticipant {
    let name: String
    let isSelf: Bool
    var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return (letters.isEmpty ? String(name.prefix(1)) : letters).uppercased()
    }
    /// A stable colour derived from the name, so the same person is always the same colour.
    var avatar: NSColor {
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0x5b, 0x8f, 0xf9), (0xf2, 0x8c, 0x4c), (0x4c, 0xc2, 0x8c),
            (0xc0, 0x6b, 0xf9), (0xf0, 0x6b, 0x8d), (0x3f, 0xb8, 0xc6),
        ]
        var h = 5381
        for b in name.unicodeScalars { h = ((h << 5) &+ h) &+ Int(b.value) }
        let (r, g, b) = palette[abs(h) % palette.count]
        return NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1)
    }
}

/// The look of a meeting window: chrome colours, accent, and how tiles are laid out.
struct SceneTheme {
    enum Layout { case gallery, stage }
    var window: NSColor
    var titleBar: NSColor
    var tile: NSColor
    var accent: NSColor
    var layout: Layout
    var appName: String

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
    }

    static func of(_ scene: HeroScene) -> SceneTheme {
        switch scene {
        case .zoom:
            return SceneTheme(window: rgb(0x1a, 0x1c, 0x22), titleBar: rgb(0x24, 0x27, 0x30),
                              tile: rgb(0x2b, 0x2f, 0x38), accent: rgb(0x2d, 0x8c, 0xff),
                              layout: .gallery, appName: "Zoom")
        case .teams:
            return SceneTheme(window: rgb(0x25, 0x24, 0x36), titleBar: rgb(0x2f, 0x2e, 0x44),
                              tile: rgb(0x3a, 0x39, 0x52), accent: rgb(0x77, 0x79, 0xd9),
                              layout: .gallery, appName: "Teams")
        case .meet:
            return SceneTheme(window: rgb(0x20, 0x21, 0x24), titleBar: rgb(0x2a, 0x2b, 0x2f),
                              tile: rgb(0x3c, 0x40, 0x43), accent: rgb(0x8a, 0xb4, 0xf8),
                              layout: .gallery, appName: "Meet")
        case .facetime:
            return SceneTheme(window: rgb(0x14, 0x16, 0x1a), titleBar: rgb(0x1c, 0x1e, 0x24),
                              tile: rgb(0x2c, 0x2c, 0x2e), accent: rgb(0x34, 0xc7, 0x59),
                              layout: .stage, appName: "FaceTime")
        case .plain:
            return SceneTheme(window: rgb(0xff, 0xff, 0xff), titleBar: rgb(0xf0, 0xf0, 0xf3),
                              tile: rgb(0xe8, 0xe8, 0xee), accent: rgb(0x2d, 0x8c, 0xff),
                              layout: .gallery, appName: "")
        }
    }
}

enum HeroScenes {
    // Unscaled chrome metrics, shared by the renderer so it can size the window to fit the tiles.
    static let titleHF: CGFloat = 36, toolbarHF: CGFloat = 58, padF: CGFloat = 16, gapF: CGFloat = 14

    /// A centred landscape window sized so the tiles are real 16:9 video tiles filling it: the
    /// height is the space available under the bar, the width grows with the number of people.
    static func windowSize(scale: CGFloat, availableHeight: CGFloat, tileCount: Int, maxWidth: CGFloat) -> CGSize {
        let h = availableHeight
        let contentH = h - (titleHF + toolbarHF) * scale
        let tileW = max(contentH * 16 / 9, 1)
        let n = max(1, tileCount)
        var w = 2 * padF * scale + CGFloat(n) * tileW + CGFloat(n - 1) * gapF * scale
        w = max(w, 1220 * scale / 5)          // wide enough for the toolbar and title bar
        w = min(w, maxWidth)
        return CGSize(width: w, height: h)
    }

    /// Paints a meeting-app window into `winRect` (y-up, like `HeroRender`'s canvas). Returns the
    /// y a floating transcript bar should be centred on, so it sits over the call above the toolbar.
    @discardableResult
    static func drawMeeting(_ ctx: CGContext, winRect: CGRect, scale: CGFloat,
                            theme: SceneTheme, participants: [HeroParticipant], activeIndex: Int,
                            title: String, timer: String) -> CGFloat {
        let radius = 20 * scale
        // Window shadow + body.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 40 * scale,
                      color: NSColor(white: 0, alpha: 0.22).cgColor)
        roundRect(ctx, winRect, radius: radius); ctx.setFillColor(theme.window.cgColor); ctx.fillPath()
        ctx.restoreGState()

        // Clip everything to the rounded window.
        ctx.saveGState()
        roundRect(ctx, winRect, radius: radius); ctx.clip()

        // Title bar with traffic lights, a live "recording" chip and the meeting title.
        let titleH = titleHF * scale
        let titleRect = CGRect(x: winRect.minX, y: winRect.maxY - titleH, width: winRect.width, height: titleH)
        ctx.setFillColor(theme.titleBar.cgColor); ctx.fill(titleRect)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.06).cgColor)
        ctx.fill(CGRect(x: titleRect.minX, y: titleRect.minY, width: titleRect.width, height: 1 * scale))
        let lightY = titleRect.midY
        let lights: [NSColor] = [.init(srgbRed: 0.99, green: 0.36, blue: 0.34, alpha: 1),
                                 .init(srgbRed: 0.99, green: 0.74, blue: 0.18, alpha: 1),
                                 .init(srgbRed: 0.34, green: 0.79, blue: 0.30, alpha: 1)]
        for (i, c) in lights.enumerated() {
            let d = 12 * scale
            let r = CGRect(x: winRect.minX + (18 + CGFloat(i) * 20) * scale, y: lightY - d / 2, width: d, height: d)
            ctx.setFillColor(c.cgColor); ctx.fillEllipse(in: r)
        }
        // Recording chip on the right (drawn first so the title can be centred in the space left of it).
        let chipText = "REC  \(timer)"
        let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 12 * scale, weight: .semibold)
        let chipW = (chipText as NSString).size(withAttributes: [.font: chipFont]).width + 34 * scale
        let chipRect = CGRect(x: winRect.maxX - chipW - 16 * scale, y: lightY - 13 * scale, width: chipW, height: 26 * scale)
        roundRect(ctx, chipRect, radius: 13 * scale); ctx.setFillColor(NSColor(srgbRed: 0.99, green: 0.27, blue: 0.24, alpha: 0.16).cgColor); ctx.fillPath()
        ctx.setFillColor(NSColor(srgbRed: 0.99, green: 0.3, blue: 0.27, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: chipRect.minX + 12 * scale, y: chipRect.midY - 4 * scale, width: 8 * scale, height: 8 * scale))
        drawText(chipText, font: chipFont, color: NSColor(srgbRed: 1, green: 0.6, blue: 0.58, alpha: 1),
                 x: chipRect.minX + 26 * scale, centreY: chipRect.midY)
        // Meeting title, centred in the band between the traffic lights and the chip; shrinks to fit.
        let bandMin = winRect.minX + 84 * scale, bandMax = chipRect.minX - 16 * scale
        if bandMax > bandMin, !title.isEmpty {
            var tf = NSFont.systemFont(ofSize: 14 * scale, weight: .semibold)
            while (title as NSString).size(withAttributes: [.font: tf]).width > bandMax - bandMin, tf.pointSize > 8 * scale {
                tf = NSFont.systemFont(ofSize: tf.pointSize - scale, weight: .semibold)
            }
            drawText(title, font: tf, color: NSColor(white: 1, alpha: 0.92),
                     centreX: (bandMin + bandMax) / 2, centreY: titleRect.midY)
        }

        // Content area between title bar and toolbar.
        let toolbarH = toolbarHF * scale
        let content = CGRect(x: winRect.minX, y: winRect.minY + toolbarH,
                             width: winRect.width, height: winRect.height - titleH - toolbarH)
        let pad = padF * scale
        let inner = content.insetBy(dx: pad, dy: pad)
        if theme.layout == .stage {
            // One big 16:9 remote tile centred in the content area, with you as a small self-view.
            let remotes = participants.filter { !$0.isSelf }
            let big = fit(aspect169: inner)
            if let b = remotes.first {
                drawTile(ctx, rect: big, scale: scale, theme: theme, person: b, active: true, big: true)
            }
            if let me = participants.first(where: { $0.isSelf }) {
                let w = big.width * 0.22, h = big.height * 0.30
                let r = CGRect(x: big.maxX - w - 12 * scale, y: big.maxY - h - 12 * scale, width: w, height: h)
                drawTile(ctx, rect: r, scale: scale, theme: theme, person: me, active: false)
            }
        } else {
            drawGallery(ctx, area: inner, scale: scale, theme: theme, participants: participants, activeIndex: activeIndex)
        }

        // Bottom toolbar with round call controls.
        let toolbar = CGRect(x: winRect.minX, y: winRect.minY, width: winRect.width, height: toolbarH)
        ctx.setFillColor(theme.titleBar.cgColor); ctx.fill(toolbar)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.06).cgColor)
        ctx.fill(CGRect(x: toolbar.minX, y: toolbar.maxY - 1 * scale, width: toolbar.width, height: 1 * scale))
        drawToolbar(ctx, area: toolbar, scale: scale, accent: theme.accent)

        ctx.restoreGState()   // window clip

        // The transcript bar floats over the lower part of the call, above the toolbar,
        // low enough that the participants' faces stay visible above it.
        return content.minY + content.height * 0.19
    }

    private static func drawGallery(_ ctx: CGContext, area: CGRect, scale: CGFloat, theme: SceneTheme,
                                    participants: [HeroParticipant], activeIndex: Int) {
        let n = participants.count
        guard n > 0 else { return }
        // A single row of real 16:9 video tiles, centred in the content area (dark margins around
        // them, like a real call). Faces stay well below the bar that sits above the window.
        let gap = gapF * scale
        var tileH = area.height
        var tileW = tileH * 16 / 9
        if CGFloat(n) * tileW + CGFloat(n - 1) * gap > area.width {
            tileW = (area.width - CGFloat(n - 1) * gap) / CGFloat(n)
            tileH = tileW * 9 / 16
        }
        let rowW = CGFloat(n) * tileW + CGFloat(n - 1) * gap
        let x0 = area.midX - rowW / 2
        let y0 = area.midY - tileH / 2
        for i in 0..<n {
            let x = x0 + CGFloat(i) * (tileW + gap)
            drawTile(ctx, rect: CGRect(x: x, y: y0, width: tileW, height: tileH), scale: scale,
                     theme: theme, person: participants[i], active: i == activeIndex)
        }
    }

    private static func drawTile(_ ctx: CGContext, rect: CGRect, scale: CGFloat, theme: SceneTheme,
                                 person: HeroParticipant, active: Bool, big: Bool = false) {
        let radius = 14 * scale
        ctx.saveGState()
        roundRect(ctx, rect, radius: radius); ctx.clip()
        // Subtle top-to-bottom gradient so the tile reads as video, not a flat block.
        let top = theme.tile.blended(withFraction: 0.10, of: .white) ?? theme.tile
        let bot = theme.tile.blended(withFraction: 0.35, of: .black) ?? theme.tile
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [top.cgColor, bot.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        // Avatar with initials, sitting in the upper-middle so the name chip stays clear below it.
        let d = min(rect.width, rect.height) * (big ? 0.30 : 0.36)
        let av = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2 + rect.height * (big ? 0.12 : 0.16), width: d, height: d)
        ctx.setFillColor(person.avatar.cgColor); ctx.fillEllipse(in: av)
        drawText(person.initials, font: .systemFont(ofSize: d * 0.40, weight: .semibold),
                 color: .white, centreX: av.midX, centreY: av.midY)
        ctx.restoreGState()
        // Active speaker ring.
        if active {
            roundRect(ctx, rect.insetBy(dx: 1.5 * scale, dy: 1.5 * scale), radius: radius)
            ctx.setStrokeColor(theme.accent.cgColor); ctx.setLineWidth(3 * scale); ctx.strokePath()
        }
        // Name chip, bottom-left, sized to the tile.
        let chipH = min(26 * scale, rect.height * 0.18)
        let nameFont = NSFont.systemFont(ofSize: chipH * 0.52, weight: .medium)
        let cpad = chipH * 0.42
        let label = (person.isSelf && person.name != "You") ? "\(person.name) (You)" : person.name
        let tw = (label as NSString).size(withAttributes: [.font: nameFont]).width
        let chip = CGRect(x: rect.minX + 10 * scale, y: rect.minY + 10 * scale, width: tw + cpad * 2, height: chipH)
        roundRect(ctx, chip, radius: chipH * 0.3); ctx.setFillColor(NSColor(white: 0, alpha: 0.4).cgColor); ctx.fillPath()
        drawText(label, font: nameFont, color: NSColor(white: 1, alpha: 0.95), x: chip.minX + cpad, centreY: chip.midY)
    }

    private static func drawToolbar(_ ctx: CGContext, area: CGRect, scale: CGFloat, accent: NSColor) {
        let icons = ["mic.fill", "video.fill", "rectangle.on.rectangle", "person.2.fill", "bubble.left.fill"]
        // Controls scale with the window so they never overflow a narrow call window.
        let d = min(46 * scale, max(26 * scale, area.width / 15))
        let gap = d * 0.42
        let leaveW = d * 1.55
        let total = CGFloat(icons.count) * d + CGFloat(icons.count) * gap + leaveW
        var x = area.midX - total / 2
        let y = area.midY - d / 2
        for name in icons {
            let r = CGRect(x: x, y: y, width: d, height: d)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.10).cgColor); ctx.fillEllipse(in: r)
            if let img = tintedSymbol(name, pt: d * 0.4, weight: .medium, color: NSColor(white: 1, alpha: 0.9)) {
                drawCenteredImage(ctx, img, in: r)
            }
            x += d + gap
        }
        // Leave button.
        let leave = CGRect(x: x, y: y, width: leaveW, height: d)
        roundRect(ctx, leave, radius: d / 2); ctx.setFillColor(NSColor(srgbRed: 0.9, green: 0.24, blue: 0.22, alpha: 1).cgColor); ctx.fillPath()
        if let img = tintedSymbol("phone.down.fill", pt: d * 0.42, weight: .semibold, color: .white) {
            drawCenteredImage(ctx, img, in: leave)
        }
    }

    // MARK: - Drawing helpers

    /// The largest 16:9 rectangle centred inside `rect`.
    static func fit(aspect169 rect: CGRect) -> CGRect {
        var w = rect.width, h = w * 9 / 16
        if h > rect.height { h = rect.height; w = h * 16 / 9 }
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    static func roundRect(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat) {
        ctx.beginPath(); ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    }

    static func drawText(_ s: String, font: NSFont, color: NSColor, centreX: CGFloat, centreY: CGFloat) {
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = (s as NSString).size(withAttributes: a)
        (s as NSString).draw(at: CGPoint(x: centreX - sz.width / 2, y: centreY - sz.height / 2), withAttributes: a)
    }

    static func drawText(_ s: String, font: NSFont, color: NSColor, x: CGFloat, centreY: CGFloat) {
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = (s as NSString).size(withAttributes: a)
        (s as NSString).draw(at: CGPoint(x: x, y: centreY - sz.height / 2), withAttributes: a)
    }

    private static func drawCenteredImage(_ ctx: CGContext, _ img: CGImage, in rect: CGRect) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let r = CGRect(x: rect.midX - iw / 2, y: rect.midY - ih / 2, width: iw, height: ih)
        ctx.draw(img, in: r)
    }

    /// Renders an SF Symbol tinted a solid colour into a CGImage, without touching the outer
    /// `lockFocus` context (uses its own bitmap graphics context).
    static func tintedSymbol(_ name: String, pt: CGFloat, weight: NSFont.Weight, color: NSColor) -> CGImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let s = base.size
        let w = Int(ceil(s.width)), h = Int(ceil(s.height))
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let r = NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        base.draw(in: r)
        color.set(); r.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
