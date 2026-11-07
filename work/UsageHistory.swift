import Foundation
import SwiftUI

struct UsageHistoryDay: Identifiable {
    let id: String
    let totals: [MeterProvider: Int64]

    var total: Int64 { totals.values.reduce(0, Self.adding) }

    static func adding(_ left: Int64, _ right: Int64) -> Int64 {
        addingUsage(left, right)
    }
}

enum HistoryImportStatus: Equatable {
    case importing
    case incomplete
}

@MainActor
final class UsageHistory: ObservableObject {
    private static let key = "dailyUsageHistory.v1"
    private let defaults: UserDefaults
    @Published private var days: [String: [String: Int64]]
    private var imported: [String: [String: LedgerDayTotal]]
    private var archives: [String: ArchiveUsageTotals]
    @Published private var importStatus: [MeterProvider: HistoryImportStatus] = [:]

    init(defaults: UserDefaults = .standard, ledger: LocalUsageLedger? = nil) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key)
        days = stored.flatMap { try? JSONDecoder().decode([String: [String: Int64]].self, from: $0) } ?? [:]
        imported = ledger?.savedTotals() ?? [:]
        archives = ledger?.savedArchives() ?? [:]
    }

    static func dayKey(for date: Date) -> String {
        UsageDayKey.make(for: date)
    }

    private func key(for provider: MeterProvider, home: URL) -> String {
        provider.rawValue + ":" + home.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func snapshot(for provider: MeterProvider, home: URL, at date: Date = Date()) -> DailyTokenSnapshot? {
        let source = key(for: provider, home: home)
        let day = Self.dayKey(for: date)
        guard let total = total(on: day, legacySource: source, source: LocalUsageLedger.sourceKey(legacyKey: source)) else {
            return nil
        }
        return DailyTokenSnapshot(total: total, complete: true)
    }

    func receive(_ changes: [String: LedgerDayTotal], recovered: ArchiveUsageTotals? = nil, source: String) {
        var published = false
        if let recovered {
            let previous = archives[source] ?? ArchiveUsageTotals()
            if recovered.revision >= previous.revision {
                if !recovered.hasSameBuckets(as: previous) {
                    objectWillChange.send()
                    published = true
                }
                archives[source] = recovered
            }
        }
        for (day, incoming) in changes {
            let previous = imported[source]?[day] ?? LedgerDayTotal()
            guard incoming.revision >= previous.revision, incoming != previous else { continue }
            if !published, incoming.hasEvents != previous.hasEvents
                || incoming.beforeMigration != previous.beforeMigration
                || incoming.afterMigration != previous.afterMigration {
                objectWillChange.send()
                published = true
            }
            imported[source, default: [:]][day] = incoming
        }
    }

    func oldestLegacyDay(for provider: MeterProvider, home: URL) -> String? {
        let source = key(for: provider, home: home)
        return days.keys.filter { (days[$0]?[source] ?? 0) > 0 }.min()
    }

    func archiveUsage(homes: [MeterProvider: URL]) -> ArchiveUsageTotals {
        var result = ArchiveUsageTotals()
        for (provider, home) in homes {
            guard let archive = archives[LocalUsageLedger.sourceKey(provider: provider, home: home)] else { continue }
            result.days.merge(archive.days, uniquingKeysWith: addingUsage)
            result.months.merge(archive.months, uniquingKeysWith: addingUsage)
            result.undated = addingUsage(result.undated, archive.undated)
            result.backendOnly = addingUsage(result.backendOnly, archive.backendOnly)
        }
        return result
    }

    func setImportStatus(_ status: HistoryImportStatus?, for provider: MeterProvider) {
        if importStatus[provider] != status { importStatus[provider] = status }
    }

    func importMessage(for providers: Dictionary<MeterProvider, URL>.Keys) -> String? {
        let states = providers.compactMap { importStatus[$0] }
        if states.contains(.importing) { return "正在补录历史用量，结果会陆续显示。" }
        if states.contains(.incomplete) { return "部分历史日志暂时无法导入，已保留此前保存的用量。" }
        return nil
    }

    func record(_ snapshot: DailyTokenSnapshot, for provider: MeterProvider, home: URL, at date: Date) {
        guard snapshot.complete, snapshot.total >= 0 else { return }
        let day = Self.dayKey(for: date)
        let source = key(for: provider, home: home)
        // Each scan returns a cumulative value. Preserve already recorded usage
        // if a local log disappears, and never add the same scan twice.
        if let stored = days[day]?[source], stored >= snapshot.total { return }
        days[day, default: [:]][source] = snapshot.total
        if let data = try? JSONEncoder().encode(days) { defaults.set(data, forKey: Self.key) }
    }

    func rows(homes: [MeterProvider: URL], since start: Date?) -> [UsageHistoryDay] {
        let startKey = start.map(Self.dayKey(for:))
        let sources = homes.map { provider, home in
            let legacy = key(for: provider, home: home)
            return (provider: provider, legacy: legacy, ledger: LocalUsageLedger.sourceKey(legacyKey: legacy))
        }
        var dates = Set(days.keys)
        for source in sources {
            if let ledgerDays = imported[source.ledger] { dates.formUnion(ledgerDays.keys) }
            if let archive = archives[source.ledger] { dates.formUnion(archive.days.keys) }
        }
        return dates.sorted(by: >).compactMap { day in
            guard startKey.map({ day >= $0 }) ?? true else { return nil }
            let totals = Dictionary(uniqueKeysWithValues: sources.compactMap { source in
                total(on: day, legacySource: source.legacy, source: source.ledger).map { (source.provider, $0) }
            })
            return totals.isEmpty ? nil : UsageHistoryDay(id: day, totals: totals)
        }
    }

    private func total(on day: String, legacySource: String, source: String) -> Int64? {
        let legacy = days[day]?[legacySource]
        let importedTotal = imported[source]?[day]
        let dated = importedTotal.flatMap { $0.hasEvents ? $0.includingLegacy(legacy ?? 0) : nil } ?? legacy
        guard let recovery = archives[source]?.days[day] else { return dated }
        return addingUsage(dated ?? 0, recovery)
    }
}

struct UsageHistoryView: View {
    @ObservedObject var history: UsageHistory
    let homes: [MeterProvider: URL]
    let numberStyle: DailyNumberStyle
    @Environment(\.colorScheme) private var colorScheme
    @State private var provider: MeterProvider?

    var body: some View {
        let now = Date()
        let today = UsageHistory.dayKey(for: now)
        let selectedHomes = homes.filter { provider == nil || $0.key == provider }
        let entries = history.rows(homes: selectedHomes, since: nil)
            .filter { $0.id <= today }
        let recovered = history.archiveUsage(homes: selectedHomes)
        let activity = TokenActivityCalendar(entries: entries, from: nil, through: now, minimumDays: 365)
        let total = addingUsage(activity.total, recovered.outsideDaily)
        VStack(alignment: .leading, spacing: 12) {
            sourcePicker

            if let message = history.importMessage(for: selectedHomes.keys) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(entries.isEmpty && recovered.outsideDaily == 0 ? "–" : numberStyle.format(total))
                    .font(.system(size: 25, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .help(DailyNumberStyle.exact.format(total) + " token")
                Text("token").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if let earliest = entries.last?.id, let latest = entries.first?.id {
                        Text(earliest == latest ? earliest : "\(earliest) 至 \(latest)")
                            .font(.system(size: 10).monospacedDigit())
                            .lineLimit(1)
                    }
                    Text("\(entries.count) 个记录日")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(card)

            TokenActivityChart(activity: activity, numberStyle: numberStyle)

            if !recovered.months.isEmpty || recovered.undated > 0 {
                recoveredUsage(recovered, days: entries)
            }

            if !entries.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        dayRow(entry)
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 13)
                .background(card)
            }
        }
    }

    private func recoveredUsage(_ archive: ArchiveUsageTotals, days: [UsageHistoryDay]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("归档补录")
                .font(.system(size: 12, weight: .semibold))
                .padding(.vertical, 9)
            ForEach(archive.months.keys.sorted(by: >), id: \.self) { month in
                let monthOnly = archive.months[month] ?? 0
                let dated = days.lazy.filter { $0.id.hasPrefix(month) }.map(\.total).reduce(0, addingUsage)
                Divider()
                recoveredRow("\(month) 合计", total: addingUsage(dated, monthOnly))
                    .help("其中 \(DailyNumberStyle.exact.format(monthOnly)) token 只确认到月份。")
            }
            if archive.undated > 0 {
                Divider()
                recoveredRow("未分日 · 计入总量", total: archive.undated)
            }
        }
        .padding(.horizontal, 13)
        .background(card)
    }

    private func recoveredRow(_ title: String, total: Int64) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(numberStyle.format(total) + " token")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
        }
        .padding(.vertical, 10)
    }

    private var sourcePicker: some View {
        Picker("用量来源", selection: $provider) {
            Text("总共").tag(nil as MeterProvider?)
            ForEach(MeterProvider.allCases) { item in
                Text(item.title).tag(Optional(item))
            }
        }
        .frame(width: 196)
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
    }

    private func dayRow(_ day: UsageHistoryDay) -> some View {
        HStack {
            Text(day.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Text(numberStyle.format(day.total)).font(.system(size: 13, weight: .medium, design: .monospaced))
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .help(MeterProvider.allCases.compactMap { provider in
            day.totals[provider].map { provider.title + " · " + numberStyle.format($0) + " token" }
        }.joined(separator: "\n"))
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(colorScheme == .dark ? Color(white: 0.139) : .white)
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
    }
}

@MainActor
struct TokenActivityCalendar {
    struct Day {
        let key: String
        let usage: UsageHistoryDay?
        let cumulative: Int64
    }

    struct Week: Identifiable {
        let id: Int
        var days: [Day?] = Array(repeating: nil, count: 7)
        var monthLabel: String?
        var total: Int64 = 0
        var recordedDays = 0

        var dates: [String] { days.compactMap { $0?.key } }
    }

    let weeks: [Week]
    let peakDay: Int64
    let peakWeek: Int64
    let total: Int64

    init(entries: [UsageHistoryDay], from start: Date?, through end: Date, minimumDays: Int = 1) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let dateFormat = DateFormatter()
        dateFormat.calendar = calendar
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.timeZone = calendar.timeZone
        dateFormat.dateFormat = "yyyy-MM-dd"
        let oldest = entries.map(\.id).min().flatMap(dateFormat.date(from:))
        let last = calendar.startOfDay(for: end)
        let minimumStart = calendar.date(byAdding: .day, value: 1 - minimumDays, to: last) ?? last
        var date = calendar.startOfDay(for: min(start ?? oldest ?? last, minimumStart, last))
        let byDate = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var columns: [Week] = []
        var running: Int64 = 0
        var largestDay: Int64 = 0
        var previousMonth: Int?

        while date <= last {
            let weekday = calendar.component(.weekday, from: date) - 1
            if columns.isEmpty || weekday == 0 { columns.append(Week(id: columns.count)) }
            let key = dateFormat.string(from: date)
            let usage = byDate[key]
            let count = usage?.total ?? 0
            let column = columns.count - 1
            running = UsageHistoryDay.adding(running, count)
            largestDay = max(largestDay, count)
            columns[column].days[weekday] = Day(key: key, usage: usage, cumulative: running)
            columns[column].total = UsageHistoryDay.adding(columns[column].total, count)
            if usage != nil { columns[column].recordedDays += 1 }

            let month = calendar.component(.month, from: date)
            if month != previousMonth {
                columns[column].monthLabel = "\(month)月"
                previousMonth = month
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }

        weeks = columns
        peakDay = largestDay
        peakWeek = columns.map(\.total).max() ?? 0
        total = running
    }

    static func level(for value: Int64, peak: Int64) -> Int {
        guard value > 0 else { return 0 }
        return min(10, max(1, Int(ceil(sqrt(Double(value) / Double(max(value, peak))) * 10))))
    }
}

private struct TokenActivityChart: View {
    private struct HoveredActivity {
        let title: String
        let detail: String
        let location: CGPoint
    }

    private enum Mode: String, CaseIterable, Identifiable {
        case daily = "每日", weekly = "每周", cumulative = "累计"

        var id: String { rawValue }
        var hint: String {
            switch self {
            case .daily: "悬停查看当天用量。"
            case .weekly: "每列一周，悬停查看日期和用量。"
            case .cumulative: "悬停查看截至当天的累计用量。"
            }
        }
    }

    let activity: TokenActivityCalendar
    let numberStyle: DailyNumberStyle
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: Mode = .daily
    @State private var hovered: HoveredActivity?

    private let timelineSpace = "token-activity-timeline"
    private let gap: CGFloat = 4
    private let cellSize: CGFloat = 13
    private var gridHeight: CGFloat { cellSize * 7 + gap * 6 }
    private var isDark: Bool { colorScheme == .dark }
    private var neutral: Color { isDark ? Color(hex: 0x353538) : Color(hex: 0xEAEBEF) }

    private static let darkLevels = [
        0x233E59, 0x265478, 0x286C98, 0x2C84B8, 0x339BD4,
        0x40AFE8, 0x59BDF2, 0x74CBFA, 0x91D8FF, 0xB4E5FF
    ]
    private static let lightLevels = [
        0xE3F0FF, 0xCCE4FF, 0xADD4FF, 0x8CC2FC, 0x69ACF4,
        0x4994E9, 0x2D7DDD, 0x1B69CE, 0x0C57BB, 0x06479F
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Token 活动", systemImage: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                    Text(mode.hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                modePicker
            }

            timeline
                .frame(height: gridHeight + (mode == .weekly ? 39 : 56))
                .coordinateSpace(name: timelineSpace)
                .overlay { hoverTooltip }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(isDark ? Color(hex: 0x2A2A2C) : .white)
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if #available(macOS 14.0, *) {
            timelineScrollView.defaultScrollAnchor(.trailing).id(mode)
        } else {
            ScrollViewReader { scroll in
                timelineScrollView.task(id: mode) {
                    scroll.scrollTo("timeline-latest", anchor: .trailing)
                }
            }
        }
    }

    private var timelineScrollView: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: gap) {
                ForEach(activity.weeks) { week in
                    VStack(alignment: .leading, spacing: 10) {
                        if mode == .weekly {
                            weekBar(week)
                        } else {
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { index in
                                    dayCell(week.days[index])
                                }
                            }
                        }
                        monthLabel(week.monthLabel)
                    }
                    .frame(width: cellSize)
                }
                Color.clear
                    .frame(width: 16, height: 1)
                    .accessibilityHidden(true)
                    .id("timeline-latest")
            }
            .background { ThinScrollerInstaller(axis: .horizontal) }
        }
        .scrollIndicators(.visible, axes: .horizontal)
    }

    private func monthLabel(_ label: String?) -> some View {
        Text(label ?? " ")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(width: cellSize, alignment: .leading)
            .accessibilityHidden(label == nil)
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases) { option in
                modeButton(option)
            }
        }
        .padding(2)
        .background(isDark ? Color(hex: 0x202022) : Color(hex: 0xF1F2F5), in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 1) }
    }

    private func modeButton(_ option: Mode) -> some View {
        let selected = mode == option
        return Button {
            hovered = nil
            mode = option
        } label: {
            Text(option.rawValue)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 9)
                .frame(height: 21)
                .background(selected ? Color.primary.opacity(0.1) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func dayCell(_ day: TokenActivityCalendar.Day?) -> some View {
        if let day {
            let count = day.usage?.total ?? 0
            let level = count > 0 ? TokenActivityCalendar.level(
                for: mode == .cumulative ? day.cumulative : count,
                peak: mode == .cumulative ? activity.total : activity.peakDay
            ) : 0
            activityCell(title: day.key, detail: dayDetail(day)) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(level == 0 ? neutral : Color(hex: (isDark ? Self.darkLevels : Self.lightLevels)[level - 1]))
                    .overlay {
                        if level == 0 { RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.04), lineWidth: 0.5) }
                    }
                    .frame(width: cellSize, height: cellSize)
            }
        } else {
            Color.clear.frame(width: cellSize, height: cellSize).accessibilityHidden(true)
        }
    }

    private func dayDetail(_ day: TokenActivityCalendar.Day) -> String {
        if mode == .cumulative {
            return "累计 \(numberStyle.format(day.cumulative)) token"
        }
        return day.usage.map { "当日 \(numberStyle.format($0.total)) token" } ?? "暂无记录"
    }

    private func weekBar(_ week: TokenActivityCalendar.Week) -> some View {
        let dates = week.dates
        let first = dates.first ?? ""
        let last = dates.last ?? first
        let span = first == last ? first : "\(first) 至 \(last)"
        let detail = week.recordedDays == 0 ? "暂无记录" : "本周 \(numberStyle.format(week.total)) token"
        return activityCell(title: span, detail: detail) {
            Color.clear
                .frame(width: cellSize, height: gridHeight)
                .overlay(alignment: .bottom) {
                    if week.total > 0 {
                        let height = max(4, (gridHeight - 8) * Double(week.total) / Double(activity.peakWeek))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: isDark ? 0x58B5FF : 0x0A84FF))
                            .frame(height: height)
                    }
                }
        }
    }

    private func activityCell<Content: View>(
        title: String, detail: String, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .named(timelineSpace)) { phase in
                switch phase {
                case let .active(location):
                    hovered = HoveredActivity(title: title, detail: detail, location: location)
                case .ended:
                    if hovered?.title == title { hovered = nil }
                }
            }
            .onTapGesture(coordinateSpace: .named(timelineSpace)) { location in
                hovered = HoveredActivity(title: title, detail: detail, location: location)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) · \(detail)")
    }

    private var hoverTooltip: some View {
        GeometryReader { geometry in
            if let hovered {
                let width = min(196, max(0, geometry.size.width - 8))
                let center = width / 2 + 4
                VStack(alignment: .leading, spacing: 4) {
                    Text(hovered.title)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(hovered.detail)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(width: width, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12)) }
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                .position(
                    x: min(max(hovered.location.x, center), geometry.size.width - center),
                    y: hovered.location.y + (hovered.location.y < 54 ? 32 : -32)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension Color {
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
