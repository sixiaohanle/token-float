import AppKit
import ServiceManagement
import SwiftUI

enum MeterPlacement: String, CaseIterable, Identifiable {
    case floating, menuBar, both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .floating: "悬浮球"
        case .menuBar: "菜单栏"
        case .both: "两处同时"
        }
    }

    var showsFloating: Bool { self != .menuBar }
    var showsMenuBar: Bool { self != .floating }
}

enum DailyNumberStyle: String, CaseIterable, Identifiable {
    case exact, chinese

    var id: String { rawValue }
    var title: String { self == .exact ? "完整数字" : "中文单位" }

    func format(_ value: Int64) -> String {
        if self == .chinese, value >= 10_000 {
            let units: [(Double, String)] = [
                (100_000_000, "亿"), (10_000_000, "千万"), (1_000_000, "百万"), (10_000, "万")
            ]
            if let index = units.firstIndex(where: { Double(value) >= $0.0 }) {
                let (factor, unit) = units[index]
                let scaled = (Double(value) / factor * 100).rounded() / 100
                if index > 0, scaled >= units[index - 1].0 / factor {
                    return "1" + units[index - 1].1
                }
                let digits = scaled.formatted(.number.precision(.fractionLength(0...2))
                    .locale(Locale(identifier: "zh_CN")))
                return digits + unit
            }
        }
        return value.formatted(.number.locale(Locale(identifier: "zh_CN")))
    }
}

enum MeterSettingsPage: String, CaseIterable, Identifiable {
    case general, sources, history, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "常规"
        case .sources: "数据来源"
        case .history: "用量统计"
        case .about: "关于"
        }
    }
    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .sources: "tray.full"
        case .history: "chart.bar"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class MeterPreferences: ObservableObject {
    @Published var page: MeterSettingsPage = .general
    @Published private(set) var showsCat: Bool
    @Published private(set) var placement: MeterPlacement
    @Published private(set) var dailyNumberStyle: DailyNumberStyle
    @Published private(set) var enabled: Set<MeterProvider>
    @Published private(set) var overrides: [MeterProvider: URL]
    @Published private(set) var sourceStatus: [MeterProvider: String] = [:]
    @Published private(set) var loginStatus = SMAppService.Status.notRegistered
    @Published private(set) var loginError: String?

    private let defaults: UserDefaults
    var didChange: (() -> Void)?
    var didChangeShowsCat: ((Bool) -> Void)?
    var didChangeDailyNumberStyle: ((DailyNumberStyle) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsCat = defaults.object(forKey: "showsCat") as? Bool ?? true
        placement = defaults.string(forKey: "placement").flatMap(MeterPlacement.init(rawValue:)) ?? .both
        dailyNumberStyle = defaults.string(forKey: "dailyNumberStyle").flatMap(DailyNumberStyle.init(rawValue:)) ?? .exact
        enabled = Set(MeterProvider.allCases.filter { defaults.object(forKey: "enabled.\($0.rawValue)") as? Bool ?? true })
        overrides = Dictionary(uniqueKeysWithValues: MeterProvider.allCases.compactMap { provider in
            defaults.string(forKey: "source.\(provider.rawValue)").map {
                (provider, URL(fileURLWithPath: $0, isDirectory: true))
            }
        })
    }

    func home(for provider: MeterProvider) -> URL {
        if let override = overrides[provider] { return override }
        switch provider {
        case .codex: return CodexMeter.codexHome
        case .claude: return ClaudeCodeMeter.claudeHome
        }
    }

    func setPlacement(_ value: MeterPlacement) {
        guard placement != value else { return }
        defaults.set(value.rawValue, forKey: "placement")
        placement = value
        didChange?()
    }

    func setShowsCat(_ value: Bool) {
        guard showsCat != value else { return }
        defaults.set(value, forKey: "showsCat")
        showsCat = value
        didChangeShowsCat?(value)
    }

    func setDailyNumberStyle(_ value: DailyNumberStyle) {
        guard dailyNumberStyle != value else { return }
        defaults.set(value.rawValue, forKey: "dailyNumberStyle")
        dailyNumberStyle = value
        didChangeDailyNumberStyle?(value)
    }

    func setEnabled(_ value: Bool, for provider: MeterProvider) {
        guard enabled.contains(provider) != value else { return }
        defaults.set(value, forKey: "enabled.\(provider.rawValue)")
        if value { enabled.insert(provider) } else { enabled.remove(provider) }
        didChange?()
    }

    func setHome(_ url: URL?, for provider: MeterProvider) {
        guard overrides[provider] != url else { return }
        defaults.set(url?.path, forKey: "source.\(provider.rawValue)")
        overrides[provider] = url
        didChange?()
    }

    func setStatus(_ text: String, for provider: MeterProvider) {
        if sourceStatus[provider] != text { sourceStatus[provider] = text }
    }

    var startsAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    func setStartsAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        loginError = nil
        do {
            if enabled {
                if service.status != .enabled, service.status != .requiresApproval { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            loginError = "无法更新登录项。\(error.localizedDescription)"
        }
        refreshLoginStatus()
    }
}

struct MeterSettingsView: View {
    @ObservedObject var preferences: MeterPreferences
    @ObservedObject var updates: GitHubUpdateChecker
    let history: UsageHistory
    var chooseHome: (MeterProvider) -> Void
    var rescan: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var page: MeterSettingsPage { preferences.page }

    private var dark: Bool { colorScheme == .dark }
    private var sidebarColor: Color { dark ? Color(white: 0.126) : Color(red: 0.934, green: 0.936, blue: 0.951) }
    private var contentColor: Color { dark ? Color(white: 0.094) : Color(red: 0.966, green: 0.968, blue: 0.976) }
    private var cardColor: Color { dark ? Color(white: 0.139) : .white }
    private var separator: Color { Color.primary.opacity(dark ? 0.11 : 0.075) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 148)
                .frame(maxHeight: .infinity)
                .background(sidebarColor)
            Rectangle().fill(separator).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    pageHeader
                    switch page {
                    case .general: general
                    case .sources: sources
                    case .history:
                        UsageHistoryView(
                            history: history,
                            homes: Dictionary(uniqueKeysWithValues: MeterProvider.allCases.map { ($0, preferences.home(for: $0)) }),
                            numberStyle: preferences.dailyNumberStyle
                        )
                    case .about: about
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 23)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { ThinScrollerInstaller(axis: .vertical) }
            }
            .background(contentColor)
        }
        .frame(minWidth: 620, minHeight: 408)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dark ? Color(red: 0.58, green: 0.82, blue: 0.73) : Color(red: 0.20, green: 0.48, blue: 0.40))
                    .frame(width: 26, height: 26)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                Text("设置")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 15)
            ForEach(MeterSettingsPage.allCases) { item in
                Button {
                    preferences.page = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 17)
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .background(
                        Color.primary.opacity(page == item ? (dark ? 0.10 : 0.075) : 0),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 19)
    }

    private var pageHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title).font(.system(size: 20, weight: .semibold))
                if page == .general || page == .sources {
                    Text(page == .general ? "调整悬浮球的显示与启动方式。" : "选择要读取的本机会话日志。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if page == .sources {
                Button("重新扫描", action: rescan)
                    .controlSize(.small)
            }
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard("显示") {
                settingRow("显示位置") {
                    Picker("显示位置", selection: Binding(
                        get: { preferences.placement },
                        set: { preferences.setPlacement($0) }
                    )) {
                        ForEach(MeterPlacement.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 220)
                }
                Rectangle().fill(separator).frame(height: 1)
                settingRow("在悬浮球显示小猫") {
                    Toggle("在悬浮球显示小猫", isOn: Binding(
                        get: { preferences.showsCat },
                        set: { preferences.setShowsCat($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                Rectangle().fill(separator).frame(height: 1)
                settingRow("今日累计格式", detail: "\(preferences.dailyNumberStyle.format(126_543_210)) token") {
                    Picker("今日累计格式", selection: Binding(
                        get: { preferences.dailyNumberStyle },
                        set: { preferences.setDailyNumberStyle($0) }
                    )) {
                        ForEach(DailyNumberStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 162)
                }
            }
            settingsCard("启动") {
                settingRow("登录时自动启动") {
                    Toggle("登录时自动启动", isOn: Binding(
                        get: { preferences.startsAtLogin },
                        set: { preferences.setStartsAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                if let error = preferences.loginError {
                    Text(error).font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
                }
                if preferences.loginStatus == .requiresApproval {
                    HStack {
                        Text("请在系统设置的登录项中允许启动。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("打开登录项") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Token 悬浮球").font(.system(size: 19, weight: .semibold))
                        HStack(spacing: 8) {
                            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                                Text("版本 \(version)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Button("检测更新") { Task { await updates.check() } }
                                .controlSize(.small)
                                .disabled(updates.state == .checking)
                            if updates.state == .checking {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
                Text("Token 悬浮球是一款 macOS 用量小工具。它从本机 Codex 和 Claude Code 会话日志读取数据，在桌面或菜单栏显示输出速率，并在本机保存每日 token 用量。")
                    .lineSpacing(3)
                updateStatus.font(.system(size: 11))
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(cardBackground)

            settingRow("开源地址") {
                Link(destination: updates.repositoryURL) {
                    HStack(spacing: 5) {
                        Text(updates.repositoryURL.absoluteString)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 16)
            .background(cardBackground)
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updates.state {
        case .idle, .checking:
            EmptyView()
        case .upToDate:
            Text("已是最新版本").foregroundStyle(.secondary)
        case let .available(version, url):
            HStack {
                Label("有新版本 \(version)", systemImage: "arrow.down.circle.fill")
                Spacer()
                Link("查看更新", destination: url)
            }
        case .unpublished:
            Text("GitHub 暂无正式发布。").foregroundStyle(.secondary)
        case .failed:
            Text("暂时无法检测更新，请稍后再试。").foregroundStyle(.secondary)
        }
    }

    private var sources: some View {
        VStack(spacing: 12) {
            ForEach(MeterProvider.allCases) { provider in sourceCard(provider) }
        }
    }

    private func sourceCard(_ provider: MeterProvider) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(provider == .codex ? Color(red: 0.32, green: 0.56, blue: 0.96) : Color(red: 0.25, green: 0.70, blue: 0.42))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.title).font(.system(size: 13, weight: .semibold))
                    Text(preferences.sourceStatus[provider] ?? "正在识别…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("读取\(provider.title)", isOn: Binding(
                    get: { preferences.enabled.contains(provider) },
                    set: { preferences.setEnabled($0, for: provider) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .frame(minHeight: 53)
            Rectangle().fill(separator).frame(height: 1)
            HStack(spacing: 8) {
                let path = preferences.home(for: provider).path
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Spacer(minLength: 2)
                if preferences.overrides[provider] != nil {
                    Button("恢复自动") { preferences.setHome(nil, for: provider) }
                        .controlSize(.small)
                }
                Button("选择目录…") { chooseHome(provider) }
                    .controlSize(.small)
            }
            .frame(minHeight: 46)
        }
        .padding(.horizontal, 15)
        .background(cardBackground)
    }

    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 13)
                .padding(.bottom, 3)
            content()
        }
        .padding(.horizontal, 15)
        .background(cardBackground)
    }

    private func settingRow<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            control()
        }
        .frame(minHeight: 52)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(cardColor)
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(separator, lineWidth: 1) }
    }
}
