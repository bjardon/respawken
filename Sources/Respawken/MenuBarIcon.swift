import AppKit

/// Draws the status item as three stacked meters, one per provider, top to bottom in
/// Claude / Codex / Cursor order. Fill length is utilization; colour is severity. A provider
/// that is signed out or failing renders as an empty outline so a missing reading never
/// looks like a healthy zero.
enum MenuBarIcon {
    private static let size = NSSize(width: 20, height: 16)

    static func render(results: [ProviderID: ProviderResult]) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            let barHeight: CGFloat = 3
            let gap: CGFloat = 2.5
            let width = size.width
            let total = barHeight * 3 + gap * 2
            var y = (size.height - total) / 2 + total - barHeight

            for provider in ProviderID.allCases {
                let track = NSRect(x: 0, y: y, width: width, height: barHeight)
                draw(track: track, result: results[provider])
                y -= (barHeight + gap)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(track: NSRect, result: ProviderResult?) {
        let radius = track.height / 2

        NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        guard let percent = result?.peakPercent else {
            // No reading: outline only.
            NSColor.tertiaryLabelColor.withAlphaComponent(0.7).setStroke()
            let outline = NSBezierPath(roundedRect: track.insetBy(dx: 0.25, dy: 0.25),
                                       xRadius: radius, yRadius: radius)
            outline.lineWidth = 0.5
            outline.stroke()
            return
        }

        let fraction = min(max(percent / 100, 0), 1)
        // Keep a sliver visible so "barely used" still reads as present, not absent.
        let filled = max(track.width * fraction, fraction > 0 ? track.height : 0)
        guard filled > 0 else { return }

        UsageLevel(percent: percent).nsColor.setFill()
        let fill = NSRect(x: track.minX, y: track.minY, width: filled, height: track.height)
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
