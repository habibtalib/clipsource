import AppKit
import SwiftUI

/// ClipSource glyphs drawn in code so the SwiftPM and Xcode builds share them without resource bundles.
enum BrandIcons {
    /// Menu-bar template image: clipboard with a source tag. Tinted by macOS for light and dark menu bars.
    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            NSColor.black.set()

            let board = NSBezierPath(roundedRect: NSRect(x: 3.2, y: 3.4, width: 10.4, height: 13), xRadius: 2.2, yRadius: 2.2)
            board.lineWidth = 1.5
            board.stroke()
            NSBezierPath(roundedRect: NSRect(x: 5.9, y: 1.6, width: 5, height: 3.2), xRadius: 1.2, yRadius: 1.2).fill()
            NSBezierPath(roundedRect: NSRect(x: 5.6, y: 7.4, width: 5.6, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
            NSBezierPath(roundedRect: NSRect(x: 5.6, y: 10.1, width: 3.6, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()

            let tag = NSBezierPath()
            tag.move(to: NSPoint(x: 0, y: 2.3))
            tag.line(to: NSPoint(x: 2.1, y: 0))
            tag.line(to: NSPoint(x: 7.4, y: 0))
            tag.curve(to: NSPoint(x: 8.3, y: 0.9), controlPoint1: NSPoint(x: 7.9, y: 0), controlPoint2: NSPoint(x: 8.3, y: 0.4))
            tag.line(to: NSPoint(x: 8.3, y: 4.7))
            tag.curve(to: NSPoint(x: 7.4, y: 5.6), controlPoint1: NSPoint(x: 8.3, y: 5.2), controlPoint2: NSPoint(x: 7.9, y: 5.6))
            tag.line(to: NSPoint(x: 2.1, y: 5.6))
            tag.line(to: NSPoint(x: 0, y: 3.3))
            tag.close()
            let place = AffineTransform(translationByX: 9.4, byY: 10.9)
            var rotate = AffineTransform(rotationByDegrees: -16)
            rotate.append(place)
            tag.transform(using: rotate)

            // Cut a gap around the tag so it reads as a separate shape, then fill it and punch the hole.
            context.compositingOperation = .clear
            tag.lineWidth = 2.6
            tag.stroke()
            tag.fill()
            context.compositingOperation = .sourceOver
            tag.fill()
            context.compositingOperation = .clear
            let holeCenter = NSPoint(x: 1.6, y: 2.8).applying(rotate)
            NSBezierPath(ovalIn: NSRect(x: holeCenter.x - 0.8, y: holeCenter.y - 0.8, width: 1.6, height: 1.6)).fill()
            context.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The app's own icon (AppIcon.icns in bundled builds), or a drawn badge when run unbundled.
    static var appIcon: NSImage {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil ? NSApp.applicationIconImage : badge
    }

    /// Tangerine rounded square with the white glyph, matching the logo.
    static let badge: NSImage = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        let gradient = NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.54, blue: 0.30, alpha: 1),
                                  ending: NSColor(srgbRed: 0.90, green: 0.28, blue: 0.23, alpha: 1))
        gradient?.draw(in: NSBezierPath(roundedRect: rect, xRadius: 14.5, yRadius: 14.5), angle: -45)
        let glyph = menuBar.copy() as! NSImage
        glyph.isTemplate = false
        let tinted = NSImage(size: glyph.size, flipped: false) { r in
            glyph.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect.insetBy(dx: 11, dy: 11))
        return true
    }

    /// Brand accent: tangerine, lighter on dark backgrounds.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.54, blue: 0.30, alpha: 1)
            : NSColor(srgbRed: 0.76, green: 0.25, blue: 0.05, alpha: 1)
    })
}

private extension NSPoint {
    func applying(_ t: AffineTransform) -> NSPoint { t.transform(self) }
}
