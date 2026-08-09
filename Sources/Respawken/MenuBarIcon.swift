import AppKit

/// Draws the status item as a compact grid of provider meters.
/// One column when ≤3 providers are visible; two columns (left filled first) up to 6.
/// Each row is a colour-coded identity dot plus a severity-coloured utilization bar.
enum MenuBarIcon {
    private static let maxProviders = 6
    private static let height: CGFloat = 16
    private static let singleColumnWidth: CGFloat = 22
    private static let dualColumnWidth: CGFloat = 42

    struct Entry {
        let provider: ProviderID
        let percent: Double?
        let accent: NSColor
    }

    @MainActor
    static func render(store: UsageStore) -> NSImage {
        let entries = store.iconOrder.map { provider in
            Entry(
                provider: provider,
                percent: store.results[provider]?.iconPercent(windowID: store.settings.iconWindowID(for: provider)),
                accent: store.nsAccent(for: provider)
            )
        }
        return render(entries: entries)
    }

    static func render(entries: [Entry]) -> NSImage {
        let providers = Array(entries.prefix(maxProviders))
        let columns = providers.count > 3 ? 2 : 1
        let size = NSSize(
            width: columns == 1 ? singleColumnWidth : dualColumnWidth,
            height: height
        )

        let image = NSImage(size: size, flipped: false) { _ in
            guard !providers.isEmpty else { return true }

            // Left column fills first (up to 3), then the right — so 4 providers is 3+1, not 2+2.
            let leftCount = columns == 1 ? providers.count : min(3, providers.count)
            let rightCount = columns == 1 ? 0 : max(0, providers.count - 3)
            let rowCount = max(max(leftCount, rightCount), 1)
            let barHeight: CGFloat = min(3.2, (size.height - 1) / CGFloat(rowCount) * 0.72)
            let gap: CGFloat = max(0.7, (size.height - barHeight * CGFloat(rowCount)) / CGFloat(rowCount + 1))
            let totalHeight = barHeight * CGFloat(rowCount) + gap * CGFloat(max(rowCount - 1, 0))
            let top = (size.height - totalHeight) / 2 + totalHeight - barHeight

            let columnGap: CGFloat = 3.5
            let columnWidth = columns == 1
                ? size.width
                : (size.width - columnGap) / 2
            let dotSize = barHeight
            let dotGap: CGFloat = 1.6
            let barWidth = max(columnWidth - dotSize - dotGap, 4)

            for (index, entry) in providers.enumerated() {
                let column = columns == 1 ? 0 : (index < 3 ? 0 : 1)
                let row = columns == 1 ? index : (index < 3 ? index : index - 3)
                let x = CGFloat(column) * (columnWidth + columnGap)
                let y = top - CGFloat(row) * (barHeight + gap)

                let dotRect = NSRect(
                    x: x,
                    y: y + (barHeight - dotSize) / 2,
                    width: dotSize,
                    height: dotSize
                )
                entry.accent.setFill()
                NSBezierPath(ovalIn: dotRect).fill()

                let track = NSRect(
                    x: x + dotSize + dotGap,
                    y: y,
                    width: barWidth,
                    height: barHeight
                )
                draw(track: track, percent: entry.percent)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(track: NSRect, percent: Double?) {
        let radius = track.height / 2

        // Solid light track so empty meters stay readable on a dark menu bar
        // (same idea as Stats' white capsule beside us).
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        guard let percent else {
            // No reading: keep the white track, add a soft outline so it doesn't
            // look like a healthy zero fill.
            NSColor.black.withAlphaComponent(0.22).setStroke()
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
