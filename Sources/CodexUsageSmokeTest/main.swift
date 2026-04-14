import CodexUsageCore
import Foundation

try testScansTokenDeltasAndRateLimits()
try testDoesNotDoubleCountRepeatedTotals()
try scanRealCodexHomeIfRequested()
print("CodexUsageSmokeTest passed")

private func testScansTokenDeltasAndRateLimits() throws {
    let root = try TemporaryCodexHome()
    try root.writeSession(
        year: "2026",
        month: "04",
        day: "14",
        name: "session.jsonl",
        lines: [
            """
            {"timestamp":"2026-04-14T08:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.4"}}
            """,
            """
            {"timestamp":"2026-04-14T08:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":50,"reasoning_output_tokens":10}},"rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"resets_at":1776174562},"secondary":{"used_percent":40,"window_minutes":10080,"resets_at":1776408893},"plan_type":"plus"}}}
            """,
            """
            {"timestamp":"2026-04-14T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1400,"cached_input_tokens":200,"output_tokens":80,"reasoning_output_tokens":20}}}}
            """
        ]
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let scanner = CodexUsageScanner(codexHome: root.url, calendar: calendar)
    let summary = try scanner.scan(now: testDate("2026-04-14T12:00:00.000Z"))

    precondition(summary.today.usage.inputTokens == 1400)
    precondition(summary.today.usage.cachedInputTokens == 200)
    precondition(summary.today.usage.outputTokens == 80)
    precondition(summary.today.usage.reasoningOutputTokens == 20)
    precondition(summary.today.sessions == 1)
    precondition(summary.latestRateLimits?.primary?.usedPercent == 25)
    precondition(summary.latestRateLimits?.secondary?.windowMinutes == 10080)
    precondition(summary.latestRateLimits?.planType == "plus")
    precondition(summary.topModels.first?.model == "gpt-5.4")
}

private func testDoesNotDoubleCountRepeatedTotals() throws {
    let root = try TemporaryCodexHome()
    try root.writeSession(
        year: "2026",
        month: "04",
        day: "14",
        name: "session.jsonl",
        lines: [
            """
            {"timestamp":"2026-04-14T08:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.4"}}
            """,
            """
            {"timestamp":"2026-04-14T08:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":50}}}}
            """,
            """
            {"timestamp":"2026-04-14T08:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":50}}}}
            """
        ]
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let scanner = CodexUsageScanner(codexHome: root.url, calendar: calendar)
    let summary = try scanner.scan(now: testDate("2026-04-14T12:00:00.000Z"))

    precondition(summary.today.usage.inputTokens == 1000)
    precondition(summary.today.usage.outputTokens == 50)
}

private func scanRealCodexHomeIfRequested() throws {
    guard ProcessInfo.processInfo.environment["CODEX_USAGE_SCAN_REAL_HOME"] == "1" else {
        return
    }

    let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    guard FileManager.default.fileExists(atPath: sessions.path) else {
        return
    }

    let summary = try CodexUsageScanner(codexHome: codexHome).scan()
    print("Real ~/.codex scan: \(summary.allTime.usage.totalTokens) tokens, \(summary.allTime.sessions) sessions")
}

private final class TemporaryCodexHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func writeSession(year: String, month: String, day: String, name: String, lines: [String]) throws {
        let directory = url
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

private func testDate(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)!
}
