import ImageIO
import SwiftUI

struct RunningCat: View {
    let rate: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback = KittenPlayback()
    @State private var settling = false

    private var request: PlaybackRequest {
        let value = KittenFPSProbe.shared?.rate ?? rate ?? 0
        return PlaybackRequest(rate: value.isFinite ? max(0, value) : 0, reduceMotion: reduceMotion)
    }

    var body: some View {
        let request = request
        let animate = !request.reduceMotion && (request.rate > 0 || settling)
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animate)) { _ in
            let time = ProcessInfo.processInfo.systemUptime
            let pose = request.reduceMotion ? .rest : playback.pose(at: time)
            Canvas { context, size in
                let frame = KittenFrames.draw(in: context, size: size, pose: pose)
                if case .run = pose, let frame {
                    KittenFPSProbe.shared?.record(frame)
                }
            }
        }
        .frame(width: 38, height: 27)
        .task(id: request) { await apply(request) }
        .accessibilityHidden(true)
    }

    @MainActor
    private func apply(_ request: PlaybackRequest) async {
        guard !request.reduceMotion else {
            playback = KittenPlayback()
            settling = false
            return
        }

        let duration = playback.retime(to: request.rate, at: ProcessInfo.processInfo.systemUptime)
        settling = duration > 0
        guard settling else { return }
        do {
            try await Task.sleep(for: .seconds(duration))
            settling = false
        } catch {
            // A new sample or Reduce Motion change starts a fresh request.
        }
    }
}

private struct PlaybackRequest: Equatable {
    var rate: Double
    var reduceMotion: Bool
}

struct KittenPlayback {
    enum Pose {
        case rest
        case start(Double)
        case run(Double)
        case stop(Double)
    }

    private struct Bridge {
        let start: TimeInterval
        let cadence: Double

        // The authored bridges cover 0.44 cycles with quadratic ease. This
        // duration matches their stride velocity to the loop at the seam.
        var duration: TimeInterval { 0.88 / cadence }
        var end: TimeInterval { start + duration }

        func progress(at time: TimeInterval) -> Double {
            min(1, max(0, (time - start) / duration))
        }
    }

    private struct Run {
        let start: TimeInterval
        let phase: Double
        let cadence: Double
        let target: Double
        var stopBridge: Bridge?

        func sample(at time: TimeInterval) -> (phase: Double, cadence: Double) {
            let elapsed = max(0, time - start)
            let response = 0.24
            let decay = exp(-elapsed / response)
            let change = cadence - target
            return (phase + target * elapsed + change * response * (1 - decay), target + change * decay)
        }
    }

    private enum Motion {
        case resting
        case starting(Bridge)
        case running(Run)
        case stopping(Bridge)
    }

    private var motion = Motion.resting
    private var targetCadence = 0.0

    mutating func retime(to rate: Double, at time: TimeInterval) -> TimeInterval {
        motion = currentMotion(at: time)
        targetCadence = rate > 0 ? min(2.45, 0.94 + log1p(rate / 16) * 0.48) : 0

        switch motion {
        case .resting:
            if targetCadence > 0 {
                motion = .starting(Bridge(start: time, cadence: targetCadence))
            }
        case .starting(let bridge):
            if targetCadence == 0 { return bridge.end - time + bridge.duration }
        case .running(let run):
            let sample = run.sample(at: time)
            var continuation = Run(
                start: time, phase: sample.phase, cadence: sample.cadence,
                target: targetCadence > 0 ? targetCadence : sample.cadence
            )
            if targetCadence == 0 {
                let distance = sample.phase.rounded(.up) - sample.phase
                let bridge = Bridge(start: time + distance / sample.cadence, cadence: sample.cadence)
                continuation.stopBridge = bridge
                motion = .running(continuation)
                return bridge.end - time
            }
            motion = .running(continuation)
        case .stopping(let bridge):
            if targetCadence == 0 { return bridge.end - time }
        }
        return 0
    }

    func pose(at time: TimeInterval) -> Pose {
        switch currentMotion(at: time) {
        case .resting: return .rest
        case .starting(let bridge): return .start(bridge.progress(at: time))
        case .running(let run): return .run(run.sample(at: time).phase)
        case .stopping(let bridge): return .stop(bridge.progress(at: time))
        }
    }

    private func currentMotion(at time: TimeInterval) -> Motion {
        var current = motion
        while true {
            switch current {
            case .starting(let bridge) where time >= bridge.end:
                if targetCadence > 0 {
                    return .running(Run(start: bridge.end, phase: 0, cadence: bridge.cadence, target: targetCadence))
                }
                current = .stopping(Bridge(start: bridge.end, cadence: bridge.cadence))
            case .running(let run):
                guard let bridge = run.stopBridge, time >= bridge.start else { return current }
                current = .stopping(bridge)
            case .stopping(let bridge) where time >= bridge.end:
                guard targetCadence > 0 else { return .resting }
                current = .starting(Bridge(start: bridge.end, cadence: targetCadence))
            default:
                return current
            }
        }
    }
}

private enum KittenFrames {
    struct Position: Hashable {
        var index: Int
        var frameCount: Int
    }

    private struct Frame {
        var image: Image
        var aspect: CGFloat
    }

    private static let run = load("KittenRun60", side: 8)
    private static let start = load("KittenStart60", side: 8)
    private static let stop = load("KittenStop60", side: 8)

    static func draw(in context: GraphicsContext, size: CGSize, pose: KittenPlayback.Pose) -> Position? {
        let frames: [Frame]
        let progress: Double
        let wraps: Bool
        switch pose {
        case .rest: (frames, progress, wraps) = (start, 0, false)
        case .start(let value): (frames, progress, wraps) = (start, value, false)
        case .run(let cycles): (frames, progress, wraps) = (run, cycles - cycles.rounded(.down), true)
        case .stop(let value): (frames, progress, wraps) = (stop, value, false)
        }
        guard !frames.isEmpty else { return nil }
        let intervals = wraps ? frames.count : frames.count - 1
        let index = Int((progress * Double(intervals)).rounded()) % frames.count
        let frame = frames[index]
        let width = min(size.width, size.height * frame.aspect)
        let height = width / frame.aspect
        let bounds = CGRect(
            x: (size.width - width) / 2, y: (size.height - height) / 2,
            width: width, height: height
        )
        context.draw(frame.image, in: bounds)
        return Position(index: index, frameCount: frames.count)
    }

    private static func load(_ name: String, side: Int) -> [Frame] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              image.width >= side, image.height >= side,
              image.width.isMultiple(of: side), image.height.isMultiple(of: side) else { return [] }
        let width = image.width / side
        let height = image.height / side
        var frames: [Frame] = []
        for row in 0..<side {
            for column in 0..<side {
                let cell = CGRect(x: column * width, y: row * height, width: width, height: height)
                guard let crop = image.cropping(to: cell) else { return [] }
                frames.append(Frame(
                    image: Image(decorative: crop, scale: 1),
                    aspect: CGFloat(width) / CGFloat(height)
                ))
            }
        }
        return frames
    }
}

// Enabled only for an explicit local launch. Keep the visual sampling probe
// separate from usage collection and never record session metadata.
private final class KittenFPSProbe: @unchecked Sendable {
    static let shared: KittenFPSProbe? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TOKEN_FLOAT_VERIFY_FPS"] == "1" else { return nil }
        let rate = environment["TOKEN_FLOAT_VERIFY_RATE"].flatMap(Double.init) ?? 75
        return KittenFPSProbe(rate: rate.isFinite && rate > 0 ? rate : 75)
    }()

    let rate: Double
    private let lock = NSLock()
    private var firstDraw: TimeInterval?
    private var measurementStart: TimeInterval?
    private var previousDraw: TimeInterval?
    private var previousFrame: KittenFrames.Position?
    private var distinct: Set<KittenFrames.Position> = []
    private var gaps: [TimeInterval] = []
    private var changes = 0
    private var finished = false

    private init(rate: Double) {
        self.rate = rate
    }

    func record(_ frame: KittenFrames.Position) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let first = firstDraw ?? now
        firstDraw = first
        guard now - first >= 0.65 else { return }
        let start = measurementStart ?? now
        measurementStart = start
        if let previousDraw { gaps.append(now - previousDraw) }
        previousDraw = now
        if let previousFrame, previousFrame != frame { changes += 1 }
        previousFrame = frame
        distinct.insert(frame)
        let elapsed = now - start
        guard elapsed >= 3 else { return }
        finished = true

        let sortedGaps = gaps.sorted()
        let percentileIndex = Int(Double(sortedGaps.count - 1) * 0.95)
        let p95Gap = sortedGaps[percentileIndex] * 1000
        let maximumGap = (sortedGaps.last ?? 0) * 1000
        let summary = String(
            format: "CAT_FPS rate=%.1f atlas_frames=%d elapsed=%.3f callbacks=%d redraw_fps=%.2f changes=%d change_fps=%.2f distinct_positions=%d p95_gap_ms=%.2f max_gap_ms=%.2f\n",
            rate, frame.frameCount, elapsed, gaps.count + 1, Double(gaps.count) / elapsed,
            changes, Double(changes) / elapsed, distinct.count, p95Gap, maximumGap
        )
        FileHandle.standardError.write(Data(summary.utf8))
    }
}
