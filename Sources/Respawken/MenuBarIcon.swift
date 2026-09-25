import AppKit

/// Draws the status item in one of three styles (see `MenuBarIconStyle`).
/// Meters and Status share one layout: a compact grid of provider rows, one column when ≤3
/// providers are visible, two columns (left filled first) up to 6. Each row is a colour-coded
/// identity dot plus either a filling bar (Meters) or a solid severity pill (Status).
/// App Icon is a monotone template of the app icon's segmented ring.
enum MenuBarIcon {
    private static let maxProviders = 6
    private static let height: CGFloat = 16
    private static let singleColumnWidth: CGFloat = 22
    private static let dualColumnWidth: CGFloat = 42

    struct Entry: Equatable {
        let provider: ProviderID
        let percent: Double?
        let accent: NSColor
    }

    @MainActor private static var cachedKey: ([Entry], MenuBarIconStyle)?
    @MainActor private static var cachedImage: NSImage?

    @MainActor
    static func render(store: UsageStore, style: MenuBarIconStyle? = nil) -> NSImage {
        let style = style ?? store.settings.iconStyle
        let entries = store.iconOrder.map { provider in
            Entry(
                provider: provider,
                percent: store.results[provider]?.iconPercent(windowID: store.settings.iconWindowID(for: provider)),
                accent: store.nsAccent(for: provider)
            )
        }
        if let cachedKey, cachedKey.0 == entries, cachedKey.1 == style, let cachedImage {
            return cachedImage
        }
        let image = render(entries: entries, style: style)
        cachedKey = (entries, style)
        cachedImage = image
        return image
    }

    static func render(entries: [Entry], style: MenuBarIconStyle) -> NSImage {
        switch style {
        case .meters, .status: return renderRows(entries: entries, style: style)
        case .appIcon: return renderRing(entries: entries)
        }
    }

    // MARK: - Meters / Status

    private static func renderRows(entries: [Entry], style: MenuBarIconStyle) -> NSImage {
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
                switch style {
                case .status: drawStatus(track: track, percent: entry.percent)
                default: draw(track: track, percent: entry.percent)
                }
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
            drawMissingOutline(track: track)
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

    /// The whole pill takes the severity colour; how full it is doesn't matter.
    private static func drawStatus(track: NSRect, percent: Double?) {
        let radius = track.height / 2
        guard let percent else {
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            drawMissingOutline(track: track)
            return
        }
        UsageLevel(percent: percent).nsColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
    }

    /// No reading: a soft outline on the white track so it doesn't look like a healthy zero.
    private static func drawMissingOutline(track: NSRect) {
        let radius = track.height / 2
        NSColor.black.withAlphaComponent(0.22).setStroke()
        let outline = NSBezierPath(roundedRect: track.insetBy(dx: 0.25, dy: 0.25),
                                   xRadius: radius, yRadius: radius)
        outline.lineWidth = 0.5
        outline.stroke()
    }

    // MARK: - App Icon

    private static let ringSegments = 8

    /// The app icon's ring, as a template: eight segments around a centre dot. Segments go
    /// dim clockwise from 12 o'clock as the fullest pinned window fills, like the artwork.
    /// With no readings at all, every segment is dim.
    private static func renderRing(entries: [Entry]) -> NSImage {
        let readings = entries.prefix(maxProviders).compactMap(\.percent)
        let dimCount: Int
        if let worst = readings.max() {
            let used = min(max(worst / 100, 0), 1)
            dimCount = Int((used * Double(ringSegments)).rounded())
        } else {
            dimCount = ringSegments
        }

        let size = NSSize(width: height, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: size.width / 2, y: size.height / 2)
            let lineWidth: CGFloat = 2.3
            let radius = size.width / 2 - lineWidth / 2 - 0.5
            let step = 360 / CGFloat(ringSegments)
            let gap: CGFloat = 11

            for index in 0..<ringSegments {
                // Segment 0 starts at 12 o'clock and the ring runs clockwise.
                let start = 90 - CGFloat(index) * step - gap / 2
                let end = 90 - CGFloat(index + 1) * step + gap / 2
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: start, endAngle: end, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .butt
                NSColor.black.withAlphaComponent(index < dimCount ? 0.25 : 1).setStroke()
                arc.stroke()
            }

            let dot: CGFloat = 3.6
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - dot / 2,
                                        width: dot, height: dot)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
