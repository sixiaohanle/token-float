import AppKit
import Foundation

if CommandLine.arguments.contains("--check-daily") {
    let codex = DailyTokenUsage().sample()
    let claude = ClaudeCodeMeter().sampleDaily()
    print("codex=\(codex.total) complete=\(codex.complete) claude=\(claude.total) complete=\(claude.complete)")
    exit(codex.complete ? 0 : 1)
}

if CommandLine.arguments.contains("--check-source") {
    let codex = CodexMeter().sample()
    let claude = ClaudeCodeMeter().sample()
    for (provider, snapshot) in [(MeterProvider.codex, codex), (.claude, claude)] {
        let active = snapshot.rows.filter { $0.state != .finished }
        let sampled = active.compactMap(\.rate)
        print("\(provider.rawValue) source=\(snapshot.sourceAvailable) active=\(active.count) sampled=\(sampled.count) rate=\(sampled.reduce(0, +))")
    }
    exit(codex.sourceAvailable || claude.sourceAvailable ? 0 : 1)
}

@MainActor
func runMeter() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MeterApplication()
    app.delegate = controller
    controller.start()
    withExtendedLifetime(controller) { app.run() }
}

MainActor.assumeIsolated { runMeter() }
