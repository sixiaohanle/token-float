import AppKit
import Combine
import SwiftUI

private final class MeterSourceMonitor {
    let home: URL
    let identity = UUID()
    private let rateTimer: DispatchSourceTimer
    private let dailyTimer: DispatchSourceTimer

    init(
        provider: MeterProvider, home: URL,
        receiveRate: @escaping (UUID, MeterSnapshot) -> Void,
        receiveDaily: @escaping (UUID, Date, DailyTokenSnapshot, [String: Int64]) -> Void
    ) {
        self.home = home
        let sampleRate: () -> MeterSnapshot
        let sampleDaily: (Date) -> (DailyTokenSnapshot, [String: Int64])
        switch provider {
        case .codex:
            let rate = CodexMeter(home: home)
            let daily = DailyTokenUsage(home: home)
            sampleRate = { rate.sample() }
            sampleDaily = { date in
                let snapshot = daily.sample(now: date)
                return (snapshot, daily.conversationTotals())
            }
        case .claude:
            let rate = ClaudeCodeMeter(home: home)
            let daily = ClaudeCodeMeter(home: home)
            sampleRate = { rate.sample() }
            sampleDaily = { date in
                let snapshot = daily.sampleDaily(now: date)
                return (snapshot, daily.conversationTotals())
            }
        }

        let rateQueue = DispatchQueue(label: "com.xiaohan.codex-token-float.rate.\(provider.rawValue)", qos: .utility)
        let dailyQueue = DispatchQueue(label: "com.xiaohan.codex-token-float.daily.\(provider.rawValue)", qos: .utility)
        rateTimer = DispatchSource.makeTimerSource(queue: rateQueue)
        dailyTimer = DispatchSource.makeTimerSource(queue: dailyQueue)
        let identity = identity
        rateTimer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(60))
        rateTimer.setEventHandler {
            let snapshot = sampleRate()
            DispatchQueue.main.async { receiveRate(identity, snapshot) }
        }
        dailyTimer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .milliseconds(300))
        dailyTimer.setEventHandler {
            let date = Date()
            let (snapshot, totals) = sampleDaily(date)
            DispatchQueue.main.async { receiveDaily(identity, date, snapshot, totals) }
        }
        rateTimer.resume()
        dailyTimer.resume()
    }

    deinit {
        rateTimer.cancel()
        dailyTimer.cancel()
    }
}

@MainActor
final class MeterApplication: NSObject, NSApplicationDelegate {
    private let preferences = MeterPreferences()
    private let history = UsageHistory()
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
    private var settingsWindow: NSWindow?
    private var monitors: [MeterProvider: MeterSourceMonitor] = [:]
    private var rates: [MeterProvider: MeterSnapshot] = [:]
    private var daily: [MeterProvider: DailyTokenSnapshot] = [:]
    private var conversationTotals: [MeterProvider: [String: Int64]] = [:]

    func start() {
        floating.start()
        floating.setShowsCat(preferences.showsCat)
        floating.setDailyNumberStyle(preferences.dailyNumberStyle)
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
        updateMenuReadout()
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
        guard let button = statusItem?.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
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
        menuPanel?.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        menuPanel?.orderFrontRegardless()
    }

    private func closeMenu() {
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
        picker.title = "选择\(provider.title)数据目录"
        picker.message = "选择包含「\(provider.historyFolder)」的本地数据目录。"
        picker.prompt = "使用目录"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.showsHiddenFiles = true
        picker.directoryURL = preferences.home(for: provider)
        picker.beginSheetModal(for: window) { [weak self, weak picker] result in
            guard let self, result == .OK, let url = picker?.url else { return }
            let home = url.lastPathComponent == provider.historyFolder ? url.deletingLastPathComponent() : url
            let required = home.appendingPathComponent(provider.historyFolder, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: required.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                let alert = NSAlert()
                alert.messageText = "找不到\(provider.title)日志目录"
                alert.informativeText = "请选择包含「\(provider.historyFolder)」的目录。"
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
        conversationTotals.removeAll()
        reconcileSources()
    }

    private func reconcileSources() {
        for provider in MeterProvider.allCases {
            guard preferences.enabled.contains(provider) else {
                monitors.removeValue(forKey: provider)
                rates.removeValue(forKey: provider)
                daily.removeValue(forKey: provider)
                conversationTotals.removeValue(forKey: provider)
                preferences.setStatus("已关闭", for: provider)
                continue
            }
            let home = preferences.home(for: provider)
            guard monitors[provider]?.home != home else { continue }
            preferences.setStatus("正在识别…", for: provider)
            rates.removeValue(forKey: provider)
            daily[provider] = history.snapshot(for: provider, home: home)
            conversationTotals.removeValue(forKey: provider)
            monitors[provider] = MeterSourceMonitor(
                provider: provider, home: home,
                receiveRate: { [weak self] identity, snapshot in
                    guard let self, monitors[provider]?.identity == identity else { return }
                    rates[provider] = snapshot
                    let workspaces = Set(snapshot.rows.filter { $0.state != .finished }.map(\.project))
                    let status = snapshot.sourceAvailable
                        ? (workspaces.isEmpty ? "已识别 · 当前空闲" : "\(workspaces.count) 个活跃工作区")
                        : "未找到会话日志"
                    preferences.setStatus(status, for: provider)
                    publish()
                },
                receiveDaily: { [weak self] identity, date, snapshot, totals in
                    guard let self, monitors[provider]?.identity == identity else { return }
                    history.record(snapshot, for: provider, home: home, at: date)
                    guard UsageHistory.dayKey(for: date) == UsageHistory.dayKey(for: Date()) else { return }
                    let cached = history.snapshot(for: provider, home: home, at: date)
                    daily[provider] = DailyTokenSnapshot(total: max(cached?.total ?? 0, snapshot.total), complete: snapshot.complete)
                    conversationTotals[provider] = totals
                    publish()
                }
            )
        }
        publish()
    }

    private var meters: [ProviderMeter] {
        MeterProvider.allCases.filter { preferences.enabled.contains($0) }.map { provider in
            var snapshot = rates[provider] ?? MeterSnapshot(rows: [], sourceAvailable: true)
            if let totals = conversationTotals[provider] {
                for index in snapshot.rows.indices where snapshot.rows[index].totalTokens == nil {
                    snapshot.rows[index].totalTokens = totals[snapshot.rows[index].id]
                }
            }
            return ProviderMeter(
                provider: provider,
                snapshot: snapshot,
                daily: daily[provider]
            )
        }
    }

    private func publish() {
        floating.update(meters)
        updateMenuReadout()
    }

    private func updateMenuReadout() {
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
        }
        button.toolTip = "Token 悬浮球 · 总速率 \(text) T/s"
    }
}
