import AppKit
import Foundation
import SwiftUI

/// `Respawken --probe` runs every provider once and prints what the menu bar would show.
/// Handy for checking a provider without opening the UI.
enum Probe {
    static func runIfRequested() {
        renderPreviewIfRequested()
        guard CommandLine.arguments.contains("--probe") else { return }

        let providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), CursorProvider()]
        let done = DispatchSemaphore(value: 0)

        Task {
            for provider in providers {
                let started = Date()
                let outcome = await provider.fetch()
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                print("\(provider.id.title)  [\(elapsed)ms]")

                switch outcome {
                case .ok(let snapshot):
                    let meta = [snapshot.plan, snapshot.account, snapshot.source]
                        .compactMap { $0 }.joined(separator: " · ")
                    print("  \(meta)")
                    for window in snapshot.windows {
                        let suffix = window.resetsAt.map { " resets in \(Format.countdown(to: $0))" }
                            ?? (window.isActive ? "" : " (not started)")
                        print("  - \(window.title): \(Format.percent(window.clamped))\(suffix)")
                    }
                    if let note = snapshot.note { print("  note: \(note)") }
                case .signedOut(let hint):
                    print("  signed out — \(hint)")
                case .failed(let reason, _):
                    print("  failed — \(reason)")
                }
                print("")
            }
            done.signal()
        }

        done.wait()
        exit(0)
    }

    /// `Respawken --preview [path]` renders the panel and the menu bar icon to PNGs with live
    /// data, so the UI can be inspected without granting screen-recording permission.
    private static func renderPreviewIfRequested() {
        guard CommandLine.arguments.contains("--preview") else { return }
        _ = NSApplication.shared

        let output = CommandLine.arguments.last.flatMap { $0.hasSuffix(".png") ? $0 : nil }
            ?? "/tmp/respawken-panel.png"

        // Rendering has to happen on the main thread, so gather data on a background executor
        // first and only then build the view — awaiting a main-actor task here would deadlock.
        let results = fetchAllBlocking()

        MainActor.assumeIsolated {
            let store = UsageStore(seed: results)

            let renderer = ImageRenderer(content: PanelView(store: store).background(.background))
            renderer.scale = 2
            write(renderer.nsImage, to: output, label: "panel")
            write(MenuBarIcon.render(results: results),
                  to: output.replacingOccurrences(of: ".png", with: "-icon.png"), label: "icon")
        }
        exit(0)
    }

    /// Runs every provider concurrently and blocks the caller until all have settled.
    private static func fetchAllBlocking() -> [ProviderID: ProviderResult] {
        final class Box: @unchecked Sendable { var value: [ProviderID: ProviderResult] = [:] }
        let box = Box()
        let done = DispatchSemaphore(value: 0)

        Task.detached {
            let providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), CursorProvider()]
            await withTaskGroup(of: ProviderResult.self) { group in
                for provider in providers {
                    group.addTask {
                        ProviderResult(provider: provider.id, outcome: await provider.fetch(), fetchedAt: Date())
                    }
                }
                for await result in group { box.value[result.provider] = result }
            }
            done.signal()
        }

        done.wait()
        return box.value
    }

    private static func write(_ image: NSImage?, to path: String, label: String) {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            print("\(label) -> render failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("\(label)  -> \(path)")
    }
}
