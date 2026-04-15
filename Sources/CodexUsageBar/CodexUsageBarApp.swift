import AppKit
import CodexUsageCore
import SwiftUI

@main
struct CodexUsageBarApp: App {
    @StateObject private var store = UsageStore()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
                .onAppear {
                    store.start()
                    store.refresh()
                }
        } label: {
            Label(store.menuTitle, systemImage: "chart.bar.xaxis")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSummary?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var customPath: String {
        didSet { UserDefaults.standard.set(customPath, forKey: "codexHomePath") }
    }

    private var timer: Timer?
    private var hasStarted = false

    private static let defaultCodexHome: URL =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

    var effectiveCodexHome: URL {
        guard !customPath.isEmpty else { return Self.defaultCodexHome }
        let url = URL(fileURLWithPath: customPath)
        let sessions = url.appendingPathComponent("sessions", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return Self.defaultCodexHome
    }

    var isCustomPathValid: Bool {
        guard !customPath.isEmpty else { return true }
        let sessions = URL(fileURLWithPath: customPath)
            .appendingPathComponent("sessions", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDir) && isDir.boolValue
    }

    var menuTitle: String {
        guard let total = snapshot?.today.usage.totalTokens, total > 0 else {
            return "Codex"
        }
        return "Codex \(Format.compact(total))"
    }

    init() {
        customPath = UserDefaults.standard.string(forKey: "codexHomePath") ?? ""
        refresh()
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        isLoading = true
        errorMessage = nil

        let home = effectiveCodexHome
        Task.detached {
            let scanner = CodexUsageScanner(codexHome: home)
            let result: Result<UsageSummary, Error>
            do {
                result = .success(try scanner.scan())
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [result] in
                switch result {
                case .success(let summary):
                    self.snapshot = summary
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
                self.isLoading = false
            }
        }
    }
}

private struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    @State private var selectedWindow: UsageWindow = .today
    @State private var chartMode: ChartMode = .last7Days
    @State private var heatmapMonth: Date = Date()
    @State private var modelWindow: UsageWindow = .allTime
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if let snapshot = store.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        quotaSection(snapshot)
                        tokenCards(snapshot)
                        chartSection(snapshot)
                        modelSection(snapshot)
                        footer(snapshot)
                    }
                    .padding(.bottom, 4)
                }
                .frame(width: 500, height: 640)
            } else {
                ProgressView()
                    .frame(width: 500, height: 220)
            }
        }
        .padding(18)
        .background(PanelBackground())
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex Usage")
                    .font(.title2.weight(.semibold))
                Text("This Mac")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet(store: store)
            }

            Button {
                store.refresh()
            } label: {
                Label(store.isLoading ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isLoading)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func quotaSection(_ snapshot: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let limits = snapshot.latestRateLimits {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Account Quota")
                                .font(.headline)
                            Text(quotaSubtitle(snapshot))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(Format.plan(limits.planType ?? snapshot.account?.planType))
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(Palette.yellow)
                            .background(Palette.surfaceSoft, in: Capsule())
                            .overlay(Capsule().stroke(Palette.strokeStrong, lineWidth: 1))
                    }

                    if let primary = limits.primary {
                        QuotaProgressRow(
                            title: "5h window",
                            window: primary,
                            accent: Palette.teal
                        )
                    }

                    if let secondary = limits.secondary {
                        QuotaProgressRow(
                            title: "Weekly",
                            window: secondary,
                            accent: Palette.pink
                        )
                    }
                }
                .padding(14)
                .background(
                    LinearGradient(
                        colors: [Palette.surfaceRaised, Palette.surfaceSoft, Palette.surface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(title: "Account Quota", subtitle: "Latest known local snapshot")
                    Text("No quota snapshot yet. Run Codex once, then refresh.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tokenCards(_ snapshot: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local Usage")
                        .font(.headline)
                    Text("Tokens are read from ~/.codex/sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("", selection: $selectedWindow) {
                    ForEach(UsageWindow.allCases) { window in
                        Text(window.shortTitle).tag(window)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            UsageSummaryCard(
                title: selectedWindow.title,
                summary: selectedWindow.summary(from: snapshot),
                accent: selectedWindow.accent
            )
        }
    }

    private func chartSection(_ snapshot: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if chartMode == .monthly {
                    Button { heatmapMonth = Calendar.current.date(byAdding: .month, value: -1, to: heatmapMonth) ?? heatmapMonth } label: {
                        Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)

                    Text(Format.monthYear(heatmapMonth))
                        .font(.headline)
                        .frame(minWidth: 120)

                    Button { heatmapMonth = Calendar.current.date(byAdding: .month, value: 1, to: heatmapMonth) ?? heatmapMonth } label: {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Last 7 Days")
                        .font(.headline)
                }

                Spacer()

                Picker("", selection: $chartMode) {
                    ForEach(ChartMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            if chartMode == .last7Days {
                UsageBarChart(days: snapshot.recentDays)
            } else {
                MonthlyHeatmap(allDays: snapshot.allDays, month: heatmapMonth)
            }
        }
    }

    private func modelSection(_ snapshot: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Top Models").font(.headline)
                Spacer()
                Picker("", selection: $modelWindow) {
                    ForEach(UsageWindow.allCases) { w in
                        Text(w.shortTitle).tag(w)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            let models = modelsForWindow(snapshot)
            if models.isEmpty {
                Text("No model usage in this window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ModelDonutSection(models: models)
            }
        }
    }

    private func modelsForWindow(_ snapshot: UsageSummary) -> [ModelUsage] {
        switch modelWindow {
        case .allTime:
            return snapshot.topModels
        default:
            let calendar = Calendar.current
            let now = snapshot.generatedAt
            let dayCount: Int
            switch modelWindow {
            case .today: dayCount = 1
            case .last7: dayCount = 7
            case .last30: dayCount = 30
            default: dayCount = 0
            }
            let dayKeys = Set((0..<dayCount).compactMap { offset -> String? in
                guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
                let c = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            })
            return snapshot.topModelsForDays(matching: dayKeys)
        }
    }

    private func footer(_ snapshot: UsageSummary) -> some View {
        HStack {
            Text("Updated \(Format.relative(snapshot.generatedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !snapshot.warnings.isEmpty {
                Text("\(snapshot.warnings.count) files skipped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(snapshot.warnings.prefix(5).joined(separator: "\n"))
            }

            Spacer()

            Button("Open ~/.codex") {
                NSWorkspace.shared.open(snapshot.codexHome)
            }
        }
    }

    private func quotaSubtitle(_ snapshot: UsageSummary) -> String {
        guard let limits = snapshot.latestRateLimits else {
            return "Latest known local snapshot"
        }
        return "Updated \(Format.relative(limits.updatedAt))"
    }

}

private enum UsageWindow: String, CaseIterable, Identifiable {
    case today
    case last7
    case last30
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .last7: return "Last 7 Days"
        case .last30: return "Last 30 Days"
        case .allTime: return "All Time"
        }
    }

    var shortTitle: String {
        switch self {
        case .today: return "Today"
        case .last7: return "7d"
        case .last30: return "30d"
        case .allTime: return "All"
        }
    }

    var accent: Color {
        switch self {
        case .today: return Palette.teal
        case .last7: return Palette.pink
        case .last30: return Palette.yellow
        case .allTime: return Palette.mint
        }
    }

    func summary(from snapshot: UsageSummary) -> UsageWindowSummary {
        switch self {
        case .today: return snapshot.today
        case .last7: return snapshot.last7Days
        case .last30: return snapshot.last30Days
        case .allTime: return snapshot.allTime
        }
    }
}

private enum ChartMode: String, CaseIterable, Identifiable {
    case last7Days
    case monthly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .last7Days: return "7 Days"
        case .monthly: return "Monthly"
        }
    }
}


private struct SectionTitle: View {
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct QuotaProgressRow: View {
    var title: String
    var window: RateLimitWindow
    var accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))% used")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Palette.track)
                    Capsule()
                        .fill(accent)
                        .frame(width: max(6, proxy.size.width * CGFloat(window.remainingPercent / 100)))
                }
            }
            .frame(height: 8)

            HStack {
                Text("\(Int(window.remainingPercent.rounded()))% remaining")
                Spacer()
                Text(resetDetail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var resetDetail: String {
        guard let resetsAt = window.resetsAt else {
            return "Reset time unknown"
        }
        let remaining = resetsAt.timeIntervalSince(Date())
        if remaining <= 0 {
            return "Resetting now"
        }
        if remaining < 86400 {
            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            if hours > 0 {
                return minutes > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(hours)h"
            }
            return "Resets in \(minutes)m"
        }
        let days = Int(remaining) / 86_400
        let hours = (Int(remaining) % 86_400) / 3_600
        let minutes = (Int(remaining) % 3_600) / 60
        if days > 0 {
            if hours > 0 {
                return minutes > 0 ? "Resets in \(days)d \(hours)h \(minutes)m" : "Resets in \(days)d \(hours)h"
            }
            return minutes > 0 ? "Resets in \(days)d \(minutes)m" : "Resets in \(days)d"
        }
        return minutes > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(hours)h"
    }
}

private struct UsageSummaryCard: View {
    var title: String
    var summary: UsageWindowSummary
    var accent: Color

    /// Visual scaling factor for the output bar so it isn't invisible when
    /// input tokens dominate by 100×+.  The displayed number stays exact;
    /// only the bar width is multiplied.
    private static let outputBarScale: Double = 10

    private var maxTokenValue: Int64 {
        let scaledOutput = Int64(Double(summary.usage.outputTokens) * Self.outputBarScale)
        return max(summary.usage.inputTokens, scaledOutput, summary.usage.cachedInputTokens, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.currency(summary.estimatedCost))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(summary.unpricedTokens > 0 ? "\(Format.compact(summary.unpricedTokens)) unpriced" : "API-equivalent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ProportionMetric(
                title: "Input", value: Format.compact(summary.usage.inputTokens),
                rawValue: summary.usage.inputTokens, maxValue: maxTokenValue, color: Palette.cyan
            )
            ProportionMetric(
                title: "Output", value: Format.compact(summary.usage.outputTokens),
                rawValue: Int64(Double(summary.usage.outputTokens) * Self.outputBarScale),
                maxValue: maxTokenValue, color: Palette.rose
            )
            ProportionMetric(
                title: "Cached", value: Format.compact(summary.usage.cachedInputTokens),
                rawValue: summary.usage.cachedInputTokens, maxValue: maxTokenValue, color: Palette.yellow
            )

            CacheHitBar(rate: summary.cacheHitRate)

            HStack(spacing: 24) {
                InlineMetric(title: "Work time", value: Format.duration(milliseconds: summary.activeMilliseconds), color: Palette.teal)
                InlineMetric(title: "Runs", value: Format.integer(summary.runs), color: Palette.pink)
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Palette.surfaceRaised, Palette.surfaceSoft],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accent.opacity(0.24), lineWidth: 1)
        )
    }
}

private struct InlineMetric: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 4, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

private struct ProportionMetric: View {
    var title: String
    var value: String
    var rawValue: Int64
    var maxValue: Int64
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.body.weight(.semibold).monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Palette.track)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(4, proxy.size.width * CGFloat(Double(rawValue) / Double(max(maxValue, 1)))))
                }
            }
            .frame(height: 6)
        }
    }
}

private struct CacheHitBar: View {
    var rate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Cache hit rate")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(rate))
                    .font(.body.weight(.semibold).monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Palette.track)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Palette.green)
                        .frame(width: max(4, proxy.size.width * CGFloat(rate)))
                }
            }
            .frame(height: 6)
        }
    }
}

private struct UsageBarChart: View {
    var days: [DailyUsage]
    @State private var highlightedDayKey: String?

    private var maxTokens: Int64 {
        max(days.map { $0.usage.totalTokens }.max() ?? 1, 1)
    }

    private var highlightedDay: DailyUsage? {
        guard let highlightedDayKey else {
            return days.last
        }
        return days.first { $0.dayKey == highlightedDayKey } ?? days.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(days) { day in
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: day.dayKey == highlightedDay?.dayKey
                                        ? [Palette.yellow.opacity(0.92), Palette.mint.opacity(0.82)]
                                        : [Palette.cyan.opacity(0.82), Palette.teal.opacity(0.88)],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(height: barHeight(for: day))
                            .frame(maxHeight: 150, alignment: .bottom)
                            .contentShape(Rectangle())
                            .onHover { isHovering in
                                highlightedDayKey = isHovering ? day.dayKey : nil
                            }
                            .onTapGesture {
                                highlightedDayKey = day.dayKey
                            }

                        Text(Format.shortDay(day.dayKey))
                            .font(.caption2)
                            .foregroundStyle(day.dayKey == highlightedDay?.dayKey ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 180, alignment: .bottom)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .background(Palette.surfaceSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            )

            if let day = highlightedDay {
                HStack(spacing: 14) {
                    Text(day.dayKey)
                        .font(.caption.weight(.semibold))
                    MetricChip(title: "Input", value: Format.integer(day.usage.inputTokens), color: Palette.cyan)
                    MetricChip(title: "Output", value: Format.integer(day.usage.outputTokens), color: Palette.rose)
                    MetricChip(title: "Cached", value: Format.integer(day.usage.cachedInputTokens), color: Palette.yellow)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Palette.surfaceSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                )
            }
        }
    }

    private func barHeight(for day: DailyUsage) -> CGFloat {
        let ratio = Double(day.usage.totalTokens) / Double(maxTokens)
        return max(8, CGFloat(ratio) * 150)
    }

}

private struct MetricChip: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.caption)
    }
}

private struct MonthlyHeatmap: View {
    var allDays: [DailyUsage]
    var month: Date
    @State private var selectedDayKey: String?

    private var calendar: Calendar { Calendar.current }

    private var daysInMonth: Int {
        calendar.range(of: .day, in: .month, for: month)?.count ?? 30
    }

    private var firstWeekday: Int {
        let components = calendar.dateComponents([.year, .month], from: month)
        let firstDay = calendar.date(from: components) ?? month
        return (calendar.component(.weekday, from: firstDay) - calendar.firstWeekday + 7) % 7
    }

    private var monthDayKeys: [String] {
        let components = calendar.dateComponents([.year, .month], from: month)
        let year = components.year ?? 2026
        let monthNum = components.month ?? 1
        return (1...daysInMonth).map { String(format: "%04d-%02d-%02d", year, monthNum, $0) }
    }

    private var dayLookup: [String: DailyUsage] {
        var map = [String: DailyUsage]()
        for day in allDays {
            map[day.dayKey] = day
        }
        return map
    }

    private var maxTokensInMonth: Int64 {
        let keys = Set(monthDayKeys)
        return max(allDays.filter { keys.contains($0.dayKey) }.map { $0.usage.totalTokens }.max() ?? 1, 1)
    }

    var body: some View {
        let lookup = dayLookup
        let maxT = maxTokensInMonth
        let keys = monthDayKeys
        let cells: [String?] = Array(repeating: nil, count: firstWeekday) + keys

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                ForEach(calendar.veryShortWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            let rows = stride(from: 0, to: cells.count, by: 7).map { start in
                Array(cells[start..<min(start + 7, cells.count)])
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { col in
                        if col < row.count, let dayKey = row[col] {
                            let tokens = lookup[dayKey]?.usage.totalTokens ?? 0
                            let intensity = maxT > 0 ? Double(tokens) / Double(maxT) : 0
                            let dayNum = String(Int(dayKey.suffix(2))!)
                            let isSelected = selectedDayKey == dayKey

                            RoundedRectangle(cornerRadius: 2)
                                .fill(heatColor(intensity: intensity))
                                .frame(height: 28)
                                .frame(maxWidth: .infinity)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(isSelected ? Palette.yellow : .clear, lineWidth: 1.5)
                                )
                                .overlay(
                                    Text(dayNum)
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(intensity > 0.5 ? .white.opacity(0.9) : .secondary)
                                )
                                .onTapGesture { selectedDayKey = selectedDayKey == dayKey ? nil : dayKey }
                        } else {
                            Color.clear
                                .frame(height: 28)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }

            if let selected = selectedDayKey, let day = lookup[selected] {
                HStack(spacing: 10) {
                    Text(Format.shortDay(selected)).font(.caption.weight(.semibold))
                    MetricChip(title: "Input", value: Format.compact(day.usage.inputTokens), color: Palette.cyan)
                    MetricChip(title: "Output", value: Format.compact(day.usage.outputTokens), color: Palette.rose)
                    MetricChip(title: "Cached", value: Format.compact(day.usage.cachedInputTokens), color: Palette.yellow)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                )
                .padding(.top, 4)
            }

            HStack(spacing: 12) {
                Text("Less").font(.system(size: 8)).foregroundStyle(.secondary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(heatColor(intensity: level))
                        .frame(width: 10, height: 10)
                }
                Text("More").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(10)
        .background(Palette.surfaceSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        )
        .onChange(of: month) { _ in selectedDayKey = nil }
    }

    private func heatColor(intensity: Double) -> Color {
        if intensity <= 0 { return Palette.track.opacity(0.5) }
        if intensity < 0.25 { return Palette.teal.opacity(0.25) }
        if intensity < 0.50 { return Palette.teal.opacity(0.45) }
        if intensity < 0.75 { return Palette.cyan.opacity(0.55) }
        return Palette.cyan.opacity(0.80)
    }
}

private let donutColors: [Color] = [
    Palette.teal, Palette.cyan, Palette.pink, Palette.rose, Palette.yellow, Palette.mint
]

private struct ModelDonutSection: View {
    var models: [ModelUsage]
    @State private var hoveredModel: String?

    private var grandTotal: Int64 {
        max(models.reduce(0) { $0 + $1.usage.totalTokens }, 1)
    }

    private struct ArcSegment: Identifiable {
        var id: String { model }
        var model: String
        var startAngle: Angle
        var endAngle: Angle
        var color: Color
    }

    private var segments: [ArcSegment] {
        var arcs = [ArcSegment]()
        var current = Angle.degrees(-90)
        for (i, m) in models.enumerated() {
            let sweep = Angle.degrees(360 * Double(m.usage.totalTokens) / Double(grandTotal))
            arcs.append(ArcSegment(
                model: m.model,
                startAngle: current,
                endAngle: current + sweep,
                color: donutColors[i % donutColors.count]
            ))
            current = current + sweep
        }
        return arcs
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                ForEach(segments) { seg in
                    DonutArcShape(startAngle: seg.startAngle, endAngle: seg.endAngle)
                        .stroke(
                            seg.color.opacity(hoveredModel == seg.model ? 1.0 : 0.75),
                            style: StrokeStyle(lineWidth: hoveredModel == seg.model ? 28 : 22, lineCap: .butt)
                        )
                        .animation(.easeInOut(duration: 0.15), value: hoveredModel)
                        .contentShape(
                            DonutArcShape(startAngle: seg.startAngle, endAngle: seg.endAngle)
                                .stroke(style: StrokeStyle(lineWidth: 32, lineCap: .butt))
                        )
                        .onHover { isHovering in hoveredModel = isHovering ? seg.model : nil }
                }
            }
            .frame(width: 130, height: 130)
            .padding(6)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(models.enumerated()), id: \.element.id) { i, m in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(donutColors[i % donutColors.count])
                            .frame(width: 8, height: 8)
                        Text(m.model)
                            .font(.caption.weight(hoveredModel == m.model ? .bold : .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(Format.compact(m.usage.totalTokens))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onHover { isHovering in hoveredModel = isHovering ? m.model : nil }
                }

                if let hovered = hoveredModel, let m = models.first(where: { $0.model == hovered }) {
                    Divider().opacity(0.35)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            MetricChip(title: "Input", value: Format.compact(m.usage.inputTokens), color: Palette.cyan)
                            MetricChip(title: "Output", value: Format.compact(m.usage.outputTokens), color: Palette.rose)
                        }
                        HStack(spacing: 10) {
                            MetricChip(title: "Cached", value: Format.compact(m.usage.cachedInputTokens), color: Palette.yellow)
                            if m.hasKnownPricing {
                                MetricChip(title: "Cost", value: Format.currency(m.estimatedCost), color: Palette.mint)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Palette.surfaceRaised, Palette.surfaceSoft],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        )
    }
}

private struct DonutArcShape: Shape {
    var startAngle: Angle
    var endAngle: Angle

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 14
        var p = Path()
        p.addArc(center: center, radius: max(radius, 1), startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return p
    }
}

private enum Format {
    static func compact(_ value: Int64) -> String {
        let absolute = Double(abs(value))
        let sign = value < 0 ? "-" : ""

        switch absolute {
        case 1_000_000_000...:
            return "\(sign)\(oneDecimal(absolute / 1_000_000_000))b"
        case 1_000_000...:
            return "\(sign)\(oneDecimal(absolute / 1_000_000))m"
        case 1_000...:
            return "\(sign)\(oneDecimal(absolute / 1_000))k"
        default:
            return "\(value)"
        }
    }

    static func integer(_ value: Int) -> String {
        integerFormatter().string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func integer(_ value: Int64) -> String {
        integerFormatter().string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    static func currency(_ value: Double) -> String {
        if value < 0.01, value > 0 {
            return "<$0.01"
        }
        return currencyFormatter().string(from: NSNumber(value: value)) ?? "$0.00"
    }

    static func duration(milliseconds: Int64) -> String {
        let minutes = max(0, milliseconds / 60_000)
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "0m"
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func shortDay(_ dayKey: String) -> String {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3, let day = Int(parts[2]) else {
            return dayKey
        }

        let month = Int(parts[1]) ?? 1
        let symbols = Calendar.current.shortMonthSymbols
        let monthLabel = symbols.indices.contains(month - 1) ? symbols[month - 1] : "\(month)"
        return "\(monthLabel) \(day)"
    }

    static func monthYear(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    static func plan(_ value: String?) -> String {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch normalized {
        case "plus":
            return "Plus"
        case "pro":
            return "Pro"
        case "pro100", "pro_100", "pro-100":
            return "Pro $100"
        case "pro200", "pro_200", "pro-200":
            return "Pro $200"
        case "":
            return "Unknown"
        default:
            return normalized.uppercased()
        }
    }

    private static func oneDecimal(_ value: Double) -> String {
        if value >= 10 || value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private static func integerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private static func currencyFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter
    }
}

private struct SettingsSheet: View {
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss

    private var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex").path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2.weight(.semibold))

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Codex Data Path")
                        .font(.headline)

                    HStack(spacing: 6) {
                        Image(systemName: store.isCustomPathValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(store.isCustomPathValid ? Palette.green : Palette.rose)
                        Text(store.effectiveCodexHome.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 8) {
                        TextField("Custom path (leave empty for default)", text: $store.customPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())

                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.message = "Select your Codex data directory"
                            panel.directoryURL = URL(fileURLWithPath: store.customPath.isEmpty ? defaultPath : store.customPath)
                            if panel.runModal() == .OK, let url = panel.url {
                                store.customPath = url.path
                            }
                        }
                    }

                    if !store.customPath.isEmpty && !store.isCustomPathValid {
                        Text("No sessions/ folder found at this path. Using default ~/.codex instead.")
                            .font(.caption)
                            .foregroundStyle(Palette.rose)
                    }

                    HStack {
                        Button("Reset to Default") {
                            store.customPath = ""
                        }
                        .disabled(store.customPath.isEmpty)

                        Spacer()

                        Text("Default: \(defaultPath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("About")
                        .font(.headline)
                    Text("CodexUsageBar")
                        .font(.callout.weight(.medium))
                    Text("A local-only macOS menu bar monitor for Codex usage. Reads token data from ~/.codex on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Done") {
                    store.refresh()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(PanelBackground())
    }
}

private struct PanelBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Palette.panelBase,
                    Palette.panelMid,
                    Palette.panelBase
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [
                    Palette.teal.opacity(0.10),
                    .clear,
                    Palette.yellow.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private enum Palette {
    static let panelBase = Color(red: 0.10, green: 0.11, blue: 0.12)
    static let panelMid = Color(red: 0.15, green: 0.17, blue: 0.16)
    static let surface = Color(red: 0.14, green: 0.16, blue: 0.17)
    static let surfaceRaised = Color(red: 0.17, green: 0.19, blue: 0.20)
    static let surfaceSoft = Color(red: 0.13, green: 0.15, blue: 0.16)
    static let track = Color.white.opacity(0.16)
    static let stroke = Color.white.opacity(0.10)
    static let strokeStrong = Color.white.opacity(0.18)
    static let teal = Color(red: 0.35, green: 0.72, blue: 0.63)
    static let cyan = Color(red: 0.45, green: 0.64, blue: 0.80)
    static let pink = Color(red: 0.73, green: 0.46, blue: 0.57)
    static let rose = Color(red: 0.83, green: 0.54, blue: 0.47)
    static let yellow = Color(red: 0.81, green: 0.72, blue: 0.46)
    static let mint = Color(red: 0.54, green: 0.77, blue: 0.63)
    static let green = Color(red: 0.45, green: 0.72, blue: 0.55)
}
