import AppKit
import Combine
import SwiftUI

private final class HistoryImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

private final class MeterSourceMonitor {
    private typealias HistoryScanner = (
        Date, (HistoryLogRevision) -> Bool, () -> Bool, (HistoryLogRevision, [HistoryUsageEvent]) -> Void
    ) -> Bool

    let home: URL
    let identity = UUID()
    private let rateTimer: DispatchSourceTimer
    private let usageTimer: DispatchSourceTimer
    private let importCancellation = HistoryImportCancellation()

    init(
        provider: MeterProvider, home: URL, ledger: LocalUsageLedger, source: String, oldestLegacyDay: String?,
        receiveRate: @escaping (UUID, MeterSnapshot) -> Void,
        receiveDaily: @escaping (UUID, Date, Bool, [String: LedgerDayTotal], ArchiveUsageTotals?) -> Void,
        receiveHistory: @escaping (UUID, HistoryImportStatus?, [String: LedgerDayTotal], ArchiveUsageTotals?) -> Void
    ) {
        self.home = home
        let sampleRate: () -> MeterSnapshot
        let sampleDaily: ((Date) -> (events: [HistoryUsageEvent], complete: Bool))?
        let didPersistDaily: (() -> Void)?
        let scanHistory: HistoryScanner
        switch provider {
        case .antigravity:
            let rate = AntigravityMeter(home: home)
            let usage = AntigravityUsage(home: home)
            sampleRate = { rate.sample() }
            sampleDaily = nil
            didPersistDaily = nil
            scanHistory = { _, shouldRead, shouldCancel, receive in
                usage.scan(shouldRead: shouldRead, shouldCancel: shouldCancel, receive: receive)
            }
        case .codex:
            let rate = CodexMeter(home: home)
            let daily = DailyTokenUsage(home: home)
            let history = DailyTokenUsage(home: home)
            sampleRate = { rate.sample() }
            sampleDaily = daily.samplePendingUsageEvents(now:)
            didPersistDaily = daily.didPersistPendingUsage
            scanHistory = history.scanHistory(through:shouldRead:shouldCancel:receive:)
        case .claude:
            let rate = ClaudeCodeMeter(home: home)
            let daily = ClaudeCodeMeter(home: home)
            let history = ClaudeCodeMeter(home: home)
            sampleRate = { rate.sample() }
            sampleDaily = daily.samplePendingUsageEvents(now:)
            didPersistDaily = daily.didPersistPendingUsage
            scanHistory = history.scanHistory(through:shouldRead:shouldCancel:receive:)
        }

        rateTimer = Self.startRateTimer(
            provider: provider, identity: identity, interval: .milliseconds(200),
            sample: sampleRate, receive: receiveRate
        )
        let usageQueue = DispatchQueue(label: "com.xiaohan.codex-token-float.daily.\(provider.rawValue)", qos: .utility)
        let usageTimer = DispatchSource.makeTimerSource(queue: usageQueue)
        self.usageTimer = usageTimer
        let identity = identity
        let cancellation = importCancellation
        let periodicHistory = provider == .antigravity
        var lastDailyStatus: (day: String, complete: Bool)?
        var lastHistoryStatus: HistoryImportStatus? = .importing

        func importHistory(at date: Date) -> Bool {
            var pending: [String: LedgerDayTotal] = [:]
            var pendingArchive: ArchiveUsageTotals?
            var lastDelivery = Date()
            var failed = !ledger.isAvailable
            func deliver(_ status: HistoryImportStatus?) {
                let changes = pending
                let archive = pendingArchive
                pending.removeAll(keepingCapacity: true)
                pendingArchive = nil
                lastDelivery = Date()
                DispatchQueue.main.async { receiveHistory(identity, status, changes, archive) }
            }
            let complete = !failed && scanHistory(
                date,
                { ledger.needsImport($0, source: source) },
                { failed || cancellation.isCancelled },
                { file, events in
                    guard let changes = ledger.record(events, source: source, file: file, archiveChange: {
                        pendingArchive = $0
                    }) else {
                        failed = true
                        return
                    }
                    pending.merge(changes) { _, latest in latest }
                    if (!pending.isEmpty || pendingArchive != nil) && Date().timeIntervalSince(lastDelivery) >= 0.5 {
                        deliver(lastHistoryStatus)
                    }
                }
            )
            if complete && !failed && provider == .codex && !cancellation.isCancelled {
                let candidates = CodexArchiveRecovery.candidates(home: home)
                if let recovered = ledger.recordVerifiedArchives(candidates, source: source, oldestLegacyDay: oldestLegacyDay) {
                    pendingArchive = recovered
                } else {
                    failed = true
                }
                if !failed && !cancellation.isCancelled,
                   let localArchives = CodexArchiveRecovery.backendCandidates(home: home) {
                    if let recovered = ledger.recordBackendArchives(
                        localArchives, source: source, oldestLegacyDay: oldestLegacyDay
                    ) {
                        pendingArchive = recovered
                    } else {
                        failed = true
                    }
                }
            }
            let success = complete && !failed
            guard !cancellation.isCancelled else { return false }
            let status: HistoryImportStatus? = success ? nil : .incomplete
            if status != lastHistoryStatus || !pending.isEmpty || pendingArchive != nil {
                lastHistoryStatus = status
                deliver(status)
            }
            return success
        }

        usageTimer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(150))
        usageTimer.setEventHandler {
            guard !cancellation.isCancelled else { return }
            let date = Date()
            let (complete, changes, archive) = autoreleasepool { () -> (Bool, [String: LedgerDayTotal], ArchiveUsageTotals?) in
                if periodicHistory { return (importHistory(at: date), [:], nil) }
                guard let sampleDaily, ledger.isAvailable else { return (false, [:], nil) }
                let sampled = sampleDaily(date)
                var archive: ArchiveUsageTotals?
                let changes = sampled.events.isEmpty ? [:] : ledger.record(sampled.events, source: source) { archive = $0 }
                if changes != nil { didPersistDaily?() }
                return (sampled.complete && changes != nil, changes ?? [:], archive)
            }
            let day = UsageDayKey.make(for: date)
            guard !changes.isEmpty || archive != nil || lastDailyStatus?.day != day
                    || lastDailyStatus?.complete != complete else { return }
            lastDailyStatus = (day, complete)
            DispatchQueue.main.async { receiveDaily(identity, date, complete, changes, archive) }
        }
        usageTimer.resume()

        if !periodicHistory {
            DispatchQueue.global(qos: .background).async {
                _ = importHistory(at: Date())
            }
        }
    }

    private static func startRateTimer(
        provider: MeterProvider, identity: UUID, interval: DispatchTimeInterval,
        sample: @escaping () -> MeterSnapshot, receive: @escaping (UUID, MeterSnapshot) -> Void
    ) -> DispatchSourceTimer {
        let queue = DispatchQueue(label: "com.xiaohan.codex-token-float.rate.\(provider.rawValue)", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var lastRate: MeterSnapshot?
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(30))
        timer.setEventHandler {
            let snapshot = autoreleasepool(invoking: sample)
            guard lastRate != snapshot else { return }
            lastRate = snapshot
            DispatchQueue.main.async { receive(identity, snapshot) }
        }
        timer.resume()
        return timer
    }

    deinit {
        importCancellation.cancel()
        rateTimer.cancel()
        usageTimer.cancel()
    }
}

@MainActor
final class MeterApplication: NSObject, NSApplicationDelegate {
    private let preferences = MeterPreferences()
    private let ledger = LocalUsageLedger()
    private lazy var history = UsageHistory(ledger: ledger)
    private let updates = GitHubUpdateChecker(owner: "sixiaohanle", repository: "token-float")
    private var updateTask: Task<Void, Never>?
    private var updateObservation: AnyCancellable?
    private lazy var floating = TokenFloatController(
        updates: updates,
        showSettings: { [weak self] in self?.showSettings() },
        showHistory: { [weak self] in self?.showSettings(page: .history) },
        showUpdate: { [weak self] in self?.showSettings(page: .about) }
    )
    private var statusItem: NSStatusItem?
    private var menuPanel: NSPanel?
    private let menuOutsideClicks = PanelOutsideClickMonitor()
    private var settingsWindow: NSWindow?
    private var monitors: [MeterProvider: MeterSourceMonitor] = [:]
    private var rates: [MeterProvider: MeterSnapshot] = [:]
    private var daily: [MeterProvider: DailyTokenSnapshot] = [:]

    func start() {
        floating.start()
        floating.setShowsCat(preferences.showsCat)
        floating.setDailyNumberStyle(preferences.dailyNumberStyle)
        floating.setExpandedSources(preferences.expandedSources)
        preferences.didChangeExpandedSources = { [weak self] sources in
            self?.floating.setExpandedSources(sources)
        }
        preferences.didChangeShowsCat = { [weak self] value in
            self?.floating.setShowsCat(value)
        }
        preferences.didChangeDailyNumberStyle = { [weak self] style in
            self?.floating.setDailyNumberStyle(style)
        }
        preferences.didChange = { [weak self] in
            self?.applyPlacement()
            self?.reconcileSources()
        }
        applyPlacement()
        reconcileSources()
        updateObservation = updates.$state.removeDuplicates().sink { [weak self] state in
            self?.updateMenuIndicator(state)
        }
        updateTask = Task { [updates] in await updates.checkPeriodically() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTask?.cancel()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if settingsWindow?.isVisible == true { preferences.refreshLoginStatus() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if preferences.placement.showsFloating {
            floating.setVisible(true)
        } else {
            showMenu()
        }
        return false
    }

    private func applyPlacement() {
        floating.setVisible(preferences.placement.showsFloating)
        if preferences.placement.showsMenuBar {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: 77)
                let button = item.button
                button?.imagePosition = .imageLeading
                button?.target = self
                button?.action = #selector(toggleMenu)
                button?.setAccessibilityLabel("Token 悬浮球菜单")
                statusItem = item
                updateMenuIndicator(updates.state)
            }
        } else if let item = statusItem {
            closeMenu()
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        updateMenuReadout(meters)
    }

    private func updateMenuIndicator(_ state: GitHubUpdateChecker.State) {
        guard let button = statusItem?.button else { return }
        if case let .available(version, _) = state {
            button.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "有新版本")
            button.setAccessibilityLabel("Token 悬浮球菜单，有新版本 \(version)")
        } else {
            button.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Token 悬浮球")
            button.setAccessibilityLabel("Token 悬浮球菜单")
        }
    }

    @objc private func toggleMenu() {
        if menuPanel?.isVisible == true { closeMenu() } else { showMenu() }
    }

    private func showMenu() {
        guard let button = statusItem?.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? window.screen ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 5, dy: 5)
        let size = floating.menuContentSize(in: bounds)
        if menuPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.title = "Token 悬浮球 · 菜单栏"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentView = floating.makeMenuContent(size: size) { [weak self] in self?.closeMenu() }
            menuPanel = panel
        }
        let x = min(max(bounds.minX, anchor.midX - size.width / 2), max(bounds.minX, bounds.maxX - size.width))
        let y = max(bounds.minY, min(bounds.maxY, anchor.minY) - size.height)
        guard let panel = menuPanel else { return }
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.orderFrontRegardless()
        menuOutsideClicks.start(panel: panel, toggleButton: button) { [weak self] in self?.closeMenu() }
    }

    private func closeMenu() {
        menuOutsideClicks.stop()
        menuPanel?.orderOut(nil)
    }

    private func showSettings(page: MeterSettingsPage? = nil) {
        closeMenu()
        if let page { preferences.page = page }
        preferences.refreshLoginStatus()
        if settingsWindow == nil {
            let root = MeterSettingsView(
                preferences: preferences,
                updates: updates,
                history: history,
                chooseHome: { [weak self] in self?.chooseHome(for: $0) },
                rescan: { [weak self] in self?.rescan() }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 408),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "Token 悬浮球设置"
            window.acceptsMouseMovedEvents = true
            window.contentViewController = NSHostingController(rootView: root)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func chooseHome(for provider: MeterProvider) {
        guard let window = settingsWindow else { return }
        let picker = NSOpenPanel()
        let folders = provider.historyFolders
        let folderLabel = folders.joined(separator: "」或「")
        picker.title = "选择\(provider.title)数据目录"
        let instructions = provider == .antigravity
            ? "选择 .gemini 目录以读取 App 和 IDE，或选择含有 conversations 的产品目录。"
            : "选择包含「\(folderLabel)」的本地数据目录。"
        picker.message = instructions
        picker.prompt = "使用目录"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.showsHiddenFiles = true
        picker.directoryURL = preferences.home(for: provider)
        picker.beginSheetModal(for: window) { [weak self, weak picker] result in
            guard let self, result == .OK, let url = picker?.url else { return }
            func isDirectory(_ url: URL) -> Bool {
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            let home: URL
            let valid: Bool
            if provider == .antigravity {
                home = url.lastPathComponent == "conversations" ? url.deletingLastPathComponent() : url
                valid = isDirectory(home.appendingPathComponent("conversations")) || folders.contains {
                    isDirectory(home.appendingPathComponent($0).appendingPathComponent("conversations"))
                }
            } else {
                home = folders.contains(url.lastPathComponent) ? url.deletingLastPathComponent() : url
                valid = folders.contains { isDirectory(home.appendingPathComponent($0)) }
            }
            guard valid else {
                let alert = NSAlert()
                alert.messageText = "找不到\(provider.title)日志目录"
                alert.informativeText = instructions
                alert.beginSheetModal(for: window)
                return
            }
            preferences.setHome(home.standardizedFileURL, for: provider)
        }
    }

    private func rescan() {
        monitors.removeAll()
        rates.removeAll()
        daily.removeAll()
        reconcileSources()
    }

    private func reconcileSources() {
        for provider in MeterProvider.allCases {
            guard preferences.enabled.contains(provider) else {
                monitors.removeValue(forKey: provider)
                rates.removeValue(forKey: provider)
                daily.removeValue(forKey: provider)
                history.setImportStatus(nil, for: provider)
                preferences.setStatus("已关闭", for: provider)
                continue
            }
            let home = preferences.home(for: provider)
            guard monitors[provider]?.home != home else { continue }
            preferences.setStatus("正在识别…", for: provider)
            rates.removeValue(forKey: provider)
            daily[provider] = history.snapshot(for: provider, home: home)
            history.setImportStatus(.importing, for: provider)
            let source = LocalUsageLedger.sourceKey(provider: provider, home: home)
            monitors[provider] = MeterSourceMonitor(
                provider: provider, home: home, ledger: ledger, source: source,
                oldestLegacyDay: history.oldestLegacyDay(for: provider, home: home),
                receiveRate: { [weak self] identity, snapshot in
                    guard let self, monitors[provider]?.identity == identity else { return }
                    rates[provider] = snapshot
                    let active = snapshot.rows.filter { $0.state != .finished }
                    let status: String
                    if !snapshot.sourceAvailable {
                        status = "未找到会话日志"
                    } else if active.isEmpty {
                        status = "已识别 · 当前空闲"
                    } else if provider == .antigravity {
                        status = "\(active.count) 个对话最近有输出"
                    } else {
                        status = "\(Set(active.map(\.project)).count) 个活跃工作区"
                    }
                    preferences.setStatus(status, for: provider)
                    publish()
                },
                receiveDaily: { [weak self] identity, date, complete, changes, archive in
                    guard let self else { return }
                    history.receive(changes, recovered: archive, source: source)
                    guard monitors[provider]?.identity == identity else { return }
                    guard UsageHistory.dayKey(for: date) == UsageHistory.dayKey(for: Date()) else { return }
                    let cached = history.snapshot(for: provider, home: home, at: date)?.total ?? 0
                    daily[provider] = DailyTokenSnapshot(total: cached, complete: complete)
                    publish()
                },
                receiveHistory: { [weak self] identity, status, changes, archive in
                    guard let self else { return }
                    history.receive(changes, recovered: archive, source: source)
                    guard monitors[provider]?.identity == identity else { return }
                    history.setImportStatus(status, for: provider)
                    if let cached = history.snapshot(for: provider, home: home) {
                        daily[provider] = DailyTokenSnapshot(
                            total: cached.total, complete: daily[provider]?.complete ?? (status == nil)
                        )
                    }
                    publish()
                }
            )
        }
        publish()
    }

    private var meters: [ProviderMeter] {
        MeterProvider.allCases.filter { preferences.enabled.contains($0) }.map { provider in
            ProviderMeter(
                provider: provider,
                snapshot: rates[provider] ?? MeterSnapshot(rows: [], sourceAvailable: true),
                daily: daily[provider]
            )
        }
    }

    private func publish() {
        let snapshot = meters
        floating.update(snapshot)
        updateMenuReadout(snapshot)
    }

    private func updateMenuReadout(_ meters: [ProviderMeter]) {
        guard let button = statusItem?.button else { return }
        let total = ProviderMeter.combinedRate(meters)
        let text: String
        if let total, total >= 1_000 {
            text = total.formatted(.number.notation(.compactName).precision(.significantDigits(1...2))
                .locale(Locale(identifier: "en_US")))
        } else if let total {
            text = total > 0 && total < 1 ? "<1" : total.formatted(.number.precision(.fractionLength(0)))
        } else {
            text = "–"
        }
        let title = " \(text) T/s"
        if button.title != title {
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
            )
            button.toolTip = "Token 悬浮球 · 总速率 \(text) T/s"
        }
    }
}
