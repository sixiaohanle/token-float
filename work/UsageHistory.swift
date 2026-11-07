import Foundation
import SwiftUI

struct UsageHistoryDay: Identifiable {
    let id: String
    let totals: [MeterProvider: Int64]

    var total: Int64 { totals.values.reduce(0, Self.adding) }

    static func adding(_ left: Int64, _ right: Int64) -> Int64 {
        let (total, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : total
    }
}

@MainActor
final class UsageHistory: ObservableObject {
    private static let key = "dailyUsageHistory.v1"
    private let defaults: UserDefaults
    @Published private var days: [String: [String: Int64]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key)
        days = stored.flatMap { try? JSONDecoder().decode([String: [String: Int64]].self, from: $0) } ?? [:]
    }

    static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func key(for provider: MeterProvider, home: URL) -> String {
        provider.rawValue + ":" + home.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func snapshot(for provider: MeterProvider, home: URL, at date: Date = Date()) -> DailyTokenSnapshot? {
        guard let total = days[Self.dayKey(for: date)]?[key(for: provider, home: home)] else { return nil }
        return DailyTokenSnapshot(total: total, complete: true)
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
        let sources = homes.mapValues { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        return days.keys.sorted(by: >).compactMap { day in
            guard startKey.map({ day >= $0 }) ?? true, let saved = days[day] else { return nil }
            let totals = Dictionary(uniqueKeysWithValues: sources.compactMap { provider, path in
                saved[provider.rawValue + ":" + path].map { (provider, $0) }
            })
            return totals.isEmpty ? nil : UsageHistoryDay(id: day, totals: totals)
        }
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
        let activity = TokenActivityCalendar(entries: entries, from: nil, through: now, minimumDays: 365)
        let total = activity.total
        VStack(alignment: .leading, spacing: 12) {
            sourcePicker

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(entries.isEmpty ? "–" : numberStyle.format(total))
                    .font(.system(size: 25, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .help(DailyNumberStyle.exact.format(total) + " token")
                Text("token").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(entries.count) 个记录日")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(card)

            TokenActivityChart(activity: activity, numberStyle: numberStyle)

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

    private var sourcePicker: some View {
        Picker("用量来源", selection: $provider) {
            Text("总共").tag(nil as MeterProvider?)
            ForEach(MeterProvider.allCases) { item in
                Text(item.title).tag(Optional(item))
            }
        }
        .frame(width: 196)
        .pickerStyle(.segmented)
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
            day.totals[provider].map { provider.title + " · " + DailyNumberStyle.exact.format($0) + " token" }
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
    private enum Mode: String, CaseIterable, Identifiable {
        case daily = "每日", weekly = "每周", cumulative = "累计"

        var id: String { rawValue }
        var hint: String {
            switch self {
            case .daily: "悬停查看当天用量。"
            case .weekly: "悬停查看每周用量。"
            case .cumulative: "悬停查看截至当天的累计用量。"
            }
        }
    }

    let activity: TokenActivityCalendar
    let numberStyle: DailyNumberStyle
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: Mode = .daily

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

            Group {
                if mode == .weekly {
                    weeklyChart
                } else {
                    dailyChart
                }
            }
            .frame(height: gridHeight + 56)
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
    private var dailyChart: some View {
        if #available(macOS 14.0, *) {
            dailyTimeline.defaultScrollAnchor(.trailing).id(mode)
        } else {
            ScrollViewReader { scroll in
                dailyTimeline.task(id: mode) {
                    if let latest = activity.weeks.last {
                        scroll.scrollTo(latest.id, anchor: .trailing)
                    }
                }
            }
        }
    }

    private var dailyTimeline: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: gap) {
                ForEach(activity.weeks) { week in
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { index in
                                dayCell(week.days[index])
                            }
                        }
                        monthLabel(week.monthLabel, width: cellSize)
                    }
                    .frame(width: cellSize)
                }
            }
        }
        .scrollIndicators(.visible, axes: .horizontal)
    }

    private var weeklyChart: some View {
        let weeksWithHistory = activity.weeks.drop(while: { $0.recordedDays == 0 })
        let weeks = activity.weeks.suffix(max(5, weeksWithHistory.count))
        return GeometryReader { geometry in
            let visibleWeeks = min(4, max(2, Int(geometry.size.width / 120)))
            let weekWidth = geometry.size.width / CGFloat(visibleWeeks)
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 0) {
                        ForEach(weeks) { week in
                            weekColumn(week, width: weekWidth)
                        }
                    }
                }
                .scrollIndicators(.visible, axes: .horizontal)
                .task(id: weeks.last?.id) {
                    if let latest = weeks.last {
                        scroll.scrollTo(latest.id, anchor: .trailing)
                    }
                }
            }
        }
    }

    private func monthLabel(_ label: String?, width: CGFloat) -> some View {
        Text(label ?? " ")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(width: width, alignment: .leading)
            .accessibilityHidden(label == nil)
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases) { option in
                modeButton(option)
            }
        }
        .padding(3)
        .background(isDark ? Color(hex: 0x202022) : Color(hex: 0xF1F2F5), in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 1) }
    }

    private func modeButton(_ option: Mode) -> some View {
        let selected = mode == option
        return Button {
            mode = option
        } label: {
            Text(option.rawValue)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 9)
                .frame(height: 25)
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
            let label = dayLabel(day)
            RoundedRectangle(cornerRadius: 3)
                .fill(level == 0 ? neutral : Color(hex: (isDark ? Self.darkLevels : Self.lightLevels)[level - 1]))
                .overlay {
                    if level == 0 { RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.04), lineWidth: 0.5) }
                }
                .frame(width: cellSize, height: cellSize)
                .help(label)
                .accessibilityLabel(label)
        } else {
            Color.clear.frame(width: cellSize, height: cellSize).accessibilityHidden(true)
        }
    }

    private func dayLabel(_ day: TokenActivityCalendar.Day) -> String {
        let detail = day.usage.map { DailyNumberStyle.exact.format($0.total) + " token" } ?? "暂无记录"
        if mode == .cumulative {
            return "截至 \(day.key) · 累计 \(DailyNumberStyle.exact.format(day.cumulative)) token · 当日\(detail)"
        }
        return "\(day.key) · \(detail)"
    }

    private func weekColumn(_ week: TokenActivityCalendar.Week, width: CGFloat) -> some View {
        let barHeight = week.total > 0
            ? max(5, gridHeight * Double(week.total) / Double(max(1, activity.peakWeek))) : 0
        let dates = week.dates
        let first = dates.first ?? ""
        let last = dates.last ?? first
        let span = first == last ? first : "\(first) 至 \(last)"
        let shortSpan = first == last ? shortDate(first) : "\(shortDate(first))–\(shortDate(last))"
        let label = week.recordedDays == 0 ? "\(span) · 暂无记录"
            : "\(span) · \(DailyNumberStyle.exact.format(week.total)) token · \(week.recordedDays) 个记录日"
        return VStack(spacing: 6) {
            Text(week.recordedDays == 0 ? "–" : numberStyle.format(week.total))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
                .frame(height: 16)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.primary.opacity(isDark ? 0.07 : 0.05))
                if barHeight > 0 {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(hex: isDark ? 0x58B5FF : 0x0A84FF))
                        .frame(height: barHeight)
                }
            }
            .frame(width: min(86, width * 0.65), height: gridHeight)
            Text(shortSpan)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func shortDate(_ key: String) -> String {
        key.split(separator: "-").dropFirst().compactMap { Int($0) }.map { String($0) }.joined(separator: "/")
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
