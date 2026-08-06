import AppKit

/// Draws the status item as stacked meters — Claude accounts (in settings order), then Codex,
/// Cursor, and Notion AI, top to bottom. Fill length is utilization; colour is severity. A
/// provider that is signed out or failing renders as an empty outline so a missing reading
/// never looks like a healthy zero.
enum MenuBarIcon {
    private static let size = NSSize(width: 20, height: 16)

    @MainActor
    static func render(store: UsageStore) -> NSImage {
        render(results: store.results, order: store.providerOrder)
    }

    static func render(results: [ProviderID: ProviderResult], order: [ProviderID]) -> NSImage {
        let providers = order
        let image = NSImage(size: size, flipped: false) { _ in
            let count = max(CGFloat(providers.count), 1)
            let barHeight: CGFloat = min(2.4, (size.height - 1) / count * 0.7)
            let gap: CGFloat = max(0.8, (size.height - barHeight * count) / max(count + 1, 1))
            let width = size.width
            let total = barHeight * count + gap * max(count - 1, 0)
            var y = (size.height - total) / 2 + total - barHeight

            for provider in providers {
                let track = NSRect(x: 0, y: y, width: width, height: barHeight)
                draw(track: track, percent: results[provider]?.peakPercent)
                y -= (barHeight + gap)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(track: NSRect, percent: Double?) {
        let radius = track.height / 2

        NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        guard let percent else {
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
