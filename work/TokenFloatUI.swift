import AppKit
import SwiftUI

@MainActor
final class TokenFloatController {
    private let panel = TokenFloatPanel(
        contentRect: NSRect(origin: .zero, size: compactSizeWithCat),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let meter = MeterViewModel()
    private let updates: GitHubUpdateChecker
    private let showSettings: () -> Void
    private let showHistory: () -> Void
    private let showUpdate: () -> Void
    private var expanded = false
    private var started = false
    private var compactOriginBeforeExpansion: NSPoint?
    private lazy var expandedSize: NSSize = {
        guard let saved = UserDefaults.standard.string(forKey: Self.expandedSizeKey) else {
            return Self.defaultExpandedSize
        }
        let size = NSSizeFromString(saved)
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return Self.defaultExpandedSize }
        return NSSize(
            width: min(Self.maximumExpandedSize.width, max(Self.minimumExpandedSize.width, size.width)),
            height: min(Self.maximumExpandedSize.height, max(Self.minimumExpandedSize.height, size.height))
        )
    }()

    private static let compactSizeWithCat = NSSize(width: 107, height: 32)
    private static let compactSizeWithoutCat = NSSize(width: 70, height: 32)
    private static let defaultExpandedSize = NSSize(width: 336, height: 484)
    private static let minimumExpandedSize = NSSize(width: 280, height: 380)
    private static let maximumExpandedSize = NSSize(width: 620, height: 760)
    private static let expandedSizeKey = "expandedPanelSize"
    private var compactSize: NSSize { meter.showsCat ? Self.compactSizeWithCat : Self.compactSizeWithoutCat }

    init(
        updates: GitHubUpdateChecker,
        showSettings: @escaping () -> Void,
        showHistory: @escaping () -> Void,
        showUpdate: @escaping () -> Void
    ) {
        self.updates = updates
        self.showSettings = showSettings
        self.showHistory = showHistory
        self.showUpdate = showUpdate
    }

    func start() {
        guard !started else { return }
        started = true
        panel.title = "Token 悬浮球"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        let origin = visible.map {
            NSPoint(x: $0.maxX - compactSize.width - 18, y: $0.maxY - compactSize.height - 88)
        } ?? .zero
        panel.setFrame(NSRect(origin: origin, size: compactSize), display: false)
        rebuildContent()
    }

    func setVisible(_ visible: Bool) {
        if visible {
            start()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func update(_ meters: [ProviderMeter]) {
        meter.update(meters)
    }

    func setDailyNumberStyle(_ style: DailyNumberStyle) {
        meter.dailyNumberStyle = style
    }

    func setShowsCat(_ value: Bool) {
        guard meter.showsCat != value else { return }
        let oldWidth = compactSize.width
        meter.showsCat = value
        if expanded {
            compactOriginBeforeExpansion?.x += oldWidth - compactSize.width
        } else if started {
            resize(to: compactSize)
        }
    }

    func menuContentSize(in bounds: NSRect) -> NSSize {
        NSSize(width: min(expandedSize.width, bounds.width), height: min(expandedSize.height, bounds.height))
    }

    func makeMenuContent(size: NSSize, close: @escaping () -> Void) -> NSView {
        let root = hostingRoot(size: size, face: MeterFace(
            model: meter,
            updates: updates,
            expanded: true,
            collapse: close,
            showSettings: { [showSettings] in
                close()
                showSettings()
            },
            showHistory: { [showHistory] in
                close()
                showHistory()
            },
            showUpdate: showUpdate,
            menuPanel: true
        ))
        addResizeHandle(to: root)
        return root
    }

    private func toggle() {
        if expanded {
            expanded = false
            if let compactOriginBeforeExpansion {
                let frame = NSRect(origin: compactOriginBeforeExpansion, size: compactSize)
                panel.setFrame(constrained(frame), display: true)
            } else {
                resize(to: compactSize)
            }
            compactOriginBeforeExpansion = nil
        } else {
            compactOriginBeforeExpansion = panel.frame.origin
            expanded = true
            resize(to: expandedSize)
        }
        rebuildContent()
    }

    private func resize(to size: NSSize) {
        let old = panel.frame
        guard old.size != size else { return }
        let origin = NSPoint(x: old.maxX - size.width, y: old.maxY - size.height)
        panel.setFrame(constrained(NSRect(origin: origin, size: size)), display: true)
    }

    private func constrained(_ frame: NSRect, screen preferredScreen: NSScreen? = nil) -> NSRect {
        guard let screen = preferredScreen ?? panel.screen ?? NSScreen.main else { return frame }
        let bounds = screen.visibleFrame.insetBy(dx: 5, dy: 5)
        var result = frame
        result.size.width = min(frame.width, bounds.width)
        result.size.height = min(frame.height, bounds.height)
        result.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    private func hostingRoot(size: NSSize, face: MeterFace) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let content = MeterFaceHostingView(rootView: face)
        content.sizingOptions = []
        content.frame = root.bounds
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)
        return root
    }

    private func addResizeHandle(to root: NSView) {
        let resizeHandle = MeterResizeHandle(
            frame: root.bounds, minimum: Self.minimumExpandedSize, maximum: Self.maximumExpandedSize
        )
        resizeHandle.autoresizingMask = [.width, .height]
        resizeHandle.didResize = { [weak self] size in
            guard let self else { return }
            expandedSize = size
            UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.expandedSizeKey)
        }
        root.addSubview(resizeHandle)
    }

    private func rebuildContent() {
        let root = hostingRoot(size: panel.frame.size, face: MeterFace(
            model: meter,
            updates: updates,
            expanded: expanded,
            collapse: { [weak self] in self?.toggle() },
            showSettings: showSettings,
            showHistory: showHistory,
            showUpdate: showUpdate,
            menuPanel: false
        ))

        let handle = MeterDragHandle()
        handle.didClick = expanded ? nil : { [weak self] in self?.toggle() }
        handle.didDrag = { [weak self] point in
            self?.compactOriginBeforeExpansion = nil
            self?.panel.setFrameOrigin(point)
        }
        handle.didFinishDrag = { [weak self] in
            guard let self else { return }
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
            panel.setFrame(constrained(panel.frame, screen: screen), display: true)
        }
        if expanded {
            handle.frame = NSRect(x: 14, y: root.bounds.height - 55, width: root.bounds.width - 62, height: 49)
            handle.autoresizingMask = [.width, .minYMargin]
        } else {
            handle.frame = root.bounds
            handle.autoresizingMask = [.width, .height]
            handle.setAccessibilityElement(true)
            handle.setAccessibilityRole(.button)
            handle.setAccessibilityLabel("展开 Token 悬浮球")
        }
        root.addSubview(handle)
        if expanded { addResizeHandle(to: root) }

        panel.contentView = root
        panel.escape = expanded ? { [weak self] in self?.toggle() } : nil
        panel.invalidateShadow()
    }
}

private final class TokenFloatPanel: NSPanel {
    var escape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        escape?()
    }
}

private final class MeterFaceHostingView: NSHostingView<MeterFace> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class MeterResizeHandle: NSView {
    private enum Edge: CaseIterable {
        case left, right, bottom, bottomLeft, bottomRight

        var cursor: NSCursor {
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch self {
                case .left: position = .left
                case .right: position = .right
                case .bottom: position = .bottom
                case .bottomLeft: position = .bottomLeft
                case .bottomRight: position = .bottomRight
                }
                return .frameResize(position: position, directions: .all)
            }
            return self == .bottom ? .resizeUpDown : .resizeLeftRight
        }

        var changesLeft: Bool { self == .left || self == .bottomLeft }
        var changesRight: Bool { self == .right || self == .bottomRight }
        var changesBottom: Bool { self != .left && self != .right }

        func hitRegion(in bounds: NSRect) -> NSRect {
            let strip: CGFloat = 5
            let corner: CGFloat = 15
            switch self {
            case .left:
                return NSRect(x: 0, y: corner, width: strip, height: bounds.height - corner)
            case .right:
                return NSRect(x: bounds.width - strip, y: corner, width: strip, height: bounds.height - corner)
            case .bottom:
                return NSRect(x: corner, y: 0, width: bounds.width - 2 * corner, height: strip)
            case .bottomLeft:
                return NSRect(x: 0, y: 0, width: corner, height: corner)
            case .bottomRight:
                return NSRect(x: bounds.width - corner, y: 0, width: corner, height: corner)
            }
        }
    }

    private let minimum: NSSize
    private let maximum: NSSize
    private var drag: (edge: Edge, mouse: NSPoint, frame: NSRect, visible: NSRect)?
    var didResize: ((NSSize) -> Void)?

    init(frame: NSRect, minimum: NSSize, maximum: NSSize) {
        self.minimum = minimum
        self.maximum = maximum
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        edge(at: convert(point, from: superview)) == nil ? nil : self
    }

    override func resetCursorRects() {
        for edge in Edge.allCases {
            addCursorRect(edge.hitRegion(in: bounds), cursor: edge.cursor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let screen = window.screen ?? NSScreen.main,
              let edge = edge(at: convert(event.locationInWindow, from: nil)) else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        drag = (edge, mouse, window.frame, screen.visibleFrame.insetBy(dx: 5, dy: 5))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let drag else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        let dx = mouse.x - drag.mouse.x
        let dy = mouse.y - drag.mouse.y
        var frame = drag.frame
        if drag.edge.changesLeft {
            let available = drag.frame.maxX - drag.visible.minX
            frame.size.width = dimension(frame.width - dx, minimum: minimum.width, available: available, maximum: maximum.width)
            frame.origin.x = drag.frame.maxX - frame.width
        } else if drag.edge.changesRight {
            let available = drag.visible.maxX - drag.frame.minX
            frame.size.width = dimension(frame.width + dx, minimum: minimum.width, available: available, maximum: maximum.width)
        }
        if drag.edge.changesBottom {
            let available = drag.frame.maxY - drag.visible.minY
            frame.size.height = dimension(frame.height - dy, minimum: minimum.height, available: available, maximum: maximum.height)
            frame.origin.y = drag.frame.maxY - frame.height
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        if let window, let drag, window.frame.size != drag.frame.size {
            didResize?(window.frame.size)
            window.invalidateShadow()
        }
    }

    private func edge(at point: NSPoint) -> Edge? {
        Edge.allCases.first { $0.hitRegion(in: bounds).contains(point) }
    }

    private func dimension(_ value: CGFloat, minimum: CGFloat, available: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, available, max(minimum, value))
    }
}

private final class MeterDragHandle: NSView {
    var didClick: (() -> Void)?
    var didDrag: ((NSPoint) -> Void)?
    var didFinishDrag: (() -> Void)?
    private var start: (mouse: NSPoint, window: NSPoint)?
    private var dragging = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: didClick == nil ? .openHand : .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = (NSEvent.mouseLocation, window.frame.origin)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - start.mouse.x
        let dy = mouse.y - start.mouse.y
        guard dragging || hypot(dx, dy) >= 4 else { return }
        dragging = true
        didDrag?(NSPoint(x: start.window.x + dx, y: start.window.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            start = nil
            dragging = false
        }
        if dragging {
            didFinishDrag?()
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            didClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let didClick else { return false }
        didClick()
        return true
    }
}

@MainActor
private final class MeterViewModel: ObservableObject {
    @Published private(set) var providers: [ProviderMeter] = []
    @Published var dailyNumberStyle: DailyNumberStyle = .exact
    @Published var showsCat = true

    func update(_ incoming: [ProviderMeter]) {
        let next = MeterProvider.allCases.compactMap { provider -> ProviderMeter? in
            guard var entry = incoming.first(where: { $0.provider == provider }) else { return nil }
            if let previous = providers.first(where: { $0.provider == provider }) {
                var remaining = Dictionary(uniqueKeysWithValues: entry.snapshot.rows.map { ($0.id, $0) })
                let ordered = previous.snapshot.rows.compactMap { remaining.removeValue(forKey: $0.id) }
                entry.snapshot.rows = ordered + entry.snapshot.rows.filter { remaining[$0.id] != nil }
            }
            return entry
        }
        let unchanged = providers.elementsEqual(next) { before, after in
            before.provider == after.provider && before.daily == after.daily &&
                before.snapshot.sourceAvailable == after.snapshot.sourceAvailable &&
                before.snapshot.rows.elementsEqual(after.snapshot.rows) { left, right in
                    left.id == right.id && left.title == right.title &&
                        left.rate == right.rate && left.state == right.state &&
                        left.model == right.model && left.outputAt == right.outputAt &&
                        left.averageRate == right.averageRate && left.totalTokens == right.totalTokens
                }
        }
        if !unchanged { providers = next }
    }

    var dailyUsage: DailyTokenSnapshot? {
        let counts = providers.compactMap(\.daily)
        guard !counts.isEmpty else { return nil }
        return DailyTokenSnapshot(
            total: counts.reduce(0) { total, count in
                let (sum, overflow) = total.addingReportingOverflow(count.total)
                return overflow ? Int64.max : sum
            },
            complete: counts.count == providers.count && counts.allSatisfy(\.complete)
        )
    }

    var activeRows: [MeterRow] {
        providers.flatMap { entry in entry.snapshot.rows.filter { $0.state != .finished } }
    }

    var sourceAvailable: Bool {
        providers.contains { $0.snapshot.sourceAvailable }
    }

    var detailProviders: [ProviderMeter] {
        guard let codex = providers.first(where: { $0.provider == .codex }),
              let claude = providers.first(where: { $0.provider == .claude }),
              claude.snapshot.sourceAvailable else { return providers }
        let codexIsActive = codex.snapshot.sourceAvailable && codex.snapshot.rows.contains { $0.state != .finished }
        return codexIsActive ? providers : [claude, codex]
    }

    var totalRate: Double? {
        ProviderMeter.combinedRate(providers)
    }
}

private struct MeterFace: View {
    @ObservedObject var model: MeterViewModel
    @ObservedObject var updates: GitHubUpdateChecker
    let expanded: Bool
    let collapse: () -> Void
    let showSettings: () -> Void
    let showHistory: () -> Void
    let showUpdate: () -> Void
    let menuPanel: Bool

    private let mint = Color(red: 0.54, green: 0.79, blue: 0.72)
    private let foreground = Color(red: 0.95, green: 0.96, blue: 0.97)
    private let secondary = Color(red: 0.66, green: 0.68, blue: 0.72)
    private let surface = Color(red: 0.10, green: 0.11, blue: 0.13)

    var body: some View {
        Group {
            if expanded {
                GeometryReader { geometry in
                    detail(width: geometry.size.width)
                }
                .background {
                    RoundedRectangle(cornerRadius: 17)
                        .fill(surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 17)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 0.75)
                        }
                }
            } else {
                compact
                    .background {
                        Capsule()
                            .fill(surface)
                            .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.75) }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(foreground)
        .transaction { $0.disablesAnimations = true }
        .preferredColorScheme(.dark)
    }

    private var compact: some View {
        HStack(spacing: 6) {
            if model.showsCat {
                RunningCat(rate: model.totalRate)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(rate(model.totalRate, compact: true))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .frame(width: 34, alignment: .trailing)
                Text("T/s")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(secondary)
                    .frame(width: 18, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .topTrailing) {
            if case .available = updates.state {
                Circle()
                    .fill(mint)
                    .frame(width: 4, height: 4)
                    .padding([.top, .trailing], 6)
                    .accessibilityHidden(true)
            }
        }
    }

    private var glyph: some View {
        ZStack {
            Circle().fill(mint.opacity(0.15))
            Circle().strokeBorder(mint.opacity(0.23), lineWidth: 1)
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(mint)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private func detail(width: CGFloat) -> some View {
        let padding: CGFloat = width < 310 ? 11 : 14
        return VStack(alignment: .leading, spacing: 10) {
            header
            summary
            dailyUsage
            rows(width: width - 2 * padding)
            HStack {
                if case .available = updates.state {
                    Button("有新版本", action: showUpdate)
                        .buttonStyle(MeterButtonStyle())
                }
                Spacer()
                Button("用量统计", action: showHistory)
                    .buttonStyle(MeterButtonStyle())
                Button("设置", action: showSettings)
                    .buttonStyle(MeterButtonStyle())
                    .accessibilityLabel("打开 Token 悬浮球设置")
                Button("退出", action: { NSApp.terminate(nil) })
                    .buttonStyle(MeterButtonStyle())
                    .accessibilityLabel("退出 Token 悬浮球")
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            glyph
            VStack(alignment: .leading, spacing: 2) {
                Text("Token 悬浮球")
                    .font(.system(size: 14, weight: .semibold))
                Text("实时用量")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(secondary)
            }
            Spacer()
            Button(action: collapse) {
                Image(systemName: menuPanel ? "xmark" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(MeterButtonStyle())
            .help(menuPanel ? "关闭面板" : "收起")
            .accessibilityLabel(menuPanel ? "关闭面板" : "收起")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("总速率")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(secondary)
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(rate(model.totalRate))
                    .font(.system(size: 25, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .frame(width: 79, alignment: .leading)
                Text("T/s")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(secondary)
                    .fixedSize()
                Spacer(minLength: 10)
                Text(activity)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .frame(width: 84, alignment: .trailing)
            }
            if !model.providers.isEmpty {
                HStack(spacing: 8) {
                    ForEach(model.providers) { entry in
                        providerRate(entry)
                    }
                }
                .padding(.top, 5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var activity: String {
        if model.providers.isEmpty { return "未启用来源" }
        guard model.sourceAvailable else { return "会话不可读" }
        let count = model.activeRows.count
        return count == 0 ? "当前空闲" : "\(count) 个活跃对话"
    }

    private var dailyUsage: some View {
        let usage = model.dailyUsage
        let status = usage?.complete == false ? "部分来源仍在统计或无法读取" : ""
        return HStack(spacing: 6) {
            Text("今日累计")
                .font(.system(size: 11, weight: .semibold))
                .fixedSize()
            Spacer(minLength: 4)
            Text(usage.map { model.dailyNumberStyle.format($0.total) } ?? (model.providers.isEmpty ? "–" : "统计中…"))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .layoutPriority(1)
            Text("token")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(secondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityHint(status)
        .help(status)
    }

    private func rows(width: CGFloat) -> some View {
        let providers = model.detailProviders
        let wide = width >= 410
        let rateWidth = min(wide ? 140 : 101, max(85, width * 0.34))
        return DetailSessionScroll {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(providers) { entry in
                    providerSection(entry, wide: wide, rateWidth: rateWidth)
                }
            }
            .padding(.trailing, 7)
        }
        .id(providers.first?.id)
        .padding(.trailing, -7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.providers.isEmpty {
                Text("在设置中启用 Codex 或 Claude Code")
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
            }
        }
    }

    private func providerRate(_ entry: ProviderMeter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                providerDot(entry.provider)
                Text(entry.provider.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(rate(entry.rate))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .frame(width: 44, alignment: .leading)
                Text("T/s")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }

    private func providerSection(_ entry: ProviderMeter, wide: Bool, rateWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                providerDot(entry.provider)
                Text(entry.provider.title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize()
                Spacer()
                if let daily = entry.daily {
                    Text("今日 \(model.dailyNumberStyle.format(daily.total)) token")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityHint(daily.complete ? "" : "部分日志仍在统计或无法读取")
                        .help(daily.complete ? "" : "部分日志仍在统计或无法读取")
                }
            }
            .padding(.horizontal, 3)
            .frame(height: 19)
            .accessibilityAddTraits(.isHeader)
            if entry.snapshot.rows.isEmpty {
                Text(entry.snapshot.sourceAvailable ? "当前没有可显示的对话" : "暂时无法读取会话")
                    .font(.system(size: 10))
                    .foregroundStyle(secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .frame(height: 23)
            } else {
                ForEach(entry.snapshot.rows) { row in
                    rowView(row, provider: entry.provider, wide: wide, rateWidth: rateWidth)
                }
            }
        }
    }

    private func providerDot(_ provider: MeterProvider) -> some View {
        Circle()
            .fill(providerColor(provider))
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }

    private func providerColor(_ provider: MeterProvider) -> Color {
        switch provider {
        case .codex: Color(red: 85.0 / 255, green: 109.0 / 255, blue: 1)
        case .claude: Color(red: 237.0 / 255, green: 95.0 / 255, blue: 52.0 / 255)
        }
    }

    private func rowView(_ row: MeterRow, provider: MeterProvider, wide: Bool, rateWidth: CGFloat) -> some View {
        let finished = row.state == .finished
        let metadata = rowMetadata(row)
        let displayedRate = finished ? row.averageRate : row.rate
        return HStack(spacing: 8) {
            providerDot(provider)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title.isEmpty ? "未命名对话" : row.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(wide ? 2 : 1)
                    .help(row.title)
                Text(metadata)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(metadata)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if finished {
                        Text("平均")
                            .font(.system(size: 9))
                            .foregroundStyle(secondary)
                            .fixedSize()
                    }
                    Text(rate(displayedRate))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    Text("T/s")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(secondary)
                        .fixedSize()
                }
                Text(row.totalTokens.map { "\($0.formatted(.number)) token" } ?? " ")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .help("当前对话累计 · 输入 + 输出")
            }
            .frame(width: rateWidth, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .frame(height: wide ? 53 : 44)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func rate(_ value: Double?, compact: Bool = false) -> String {
        guard let value, value.isFinite else { return "–" }
        if compact, value > 0, value < 1 { return "<1" }
        if value >= 999.5 {
            return value.formatted(
                .number.notation(.compactName).precision(.significantDigits(1...2))
                    .locale(Locale(identifier: "en_US"))
            )
        }
        return value.formatted(.number.precision(.fractionLength(0...(compact ? 0 : 1))))
    }

    private func rowMetadata(_ row: MeterRow) -> String {
        let time = row.state == .finished
            ? "已结束"
            : row.outputAt.map { Self.outputTime.string(from: $0) } ?? "等待输出"
        guard let model = row.model, !model.isEmpty else { return time }
        return "\(time) · \(model)"
    }

    private static let outputTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct MeterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.96 : 0.76))
            .padding(.horizontal, 8)
            .frame(minWidth: 26, minHeight: 23)
            .background(.white.opacity(configuration.isPressed ? 0.2 : 0.085), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}
