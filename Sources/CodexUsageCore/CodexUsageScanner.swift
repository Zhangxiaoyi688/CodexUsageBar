import Foundation

public enum CodexUsageScannerError: Error, LocalizedError, Sendable {
    case missingSessionsDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case let .missingSessionsDirectory(url):
            return "No Codex sessions directory found at \(url.path)."
        }
    }
}

public struct CodexUsageScanner: Sendable {
    public var codexHome: URL
    public var calendar: Calendar

    private let maxActivityGapMilliseconds: Int64 = 2 * 60 * 1000
    private let maxLineBytes = 512_000

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        calendar: Calendar = .current
    ) {
        self.codexHome = codexHome
        self.calendar = calendar
    }

    public func scan(now: Date = Date()) throws -> UsageSummary {
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            throw CodexUsageScannerError.missingSessionsDirectory(sessionsRoot)
        }

        var warnings: [String] = []
        var daily = [String: DailyUsage]()
        var modelUsage = [String: TokenBreakdown]()
        var latestRateLimits: RateLimitSnapshot?

        for fileURL in sessionFiles(in: sessionsRoot) {
            do {
                let fileResult = try scanFile(fileURL)
                merge(fileResult.dailyUsage, into: &daily)
                merge(fileResult.modelUsage, into: &modelUsage)
                if let rateLimits = fileResult.latestRateLimits,
                   latestRateLimits == nil || rateLimits.updatedAt > latestRateLimits!.updatedAt {
                    latestRateLimits = rateLimits
                }
            } catch {
                warnings.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let sortedDays = daily.values.sorted { $0.dayKey < $1.dayKey }
        let recentDays = makeRecentDays(from: daily, now: now, count: 7)
        let todayKey = dayKey(for: now)

        let account = readAuthAccount()
        if latestRateLimits?.planType == nil {
            latestRateLimits?.planType = account?.planType
        }

        return UsageSummary(
            codexHome: codexHome,
            generatedAt: now,
            account: account,
            latestRateLimits: latestRateLimits,
            recentDays: recentDays,
            allDays: sortedDays,
            today: summarize(days: sortedDays.filter { $0.dayKey == todayKey }),
            last7Days: summarize(days: daysWithinWindow(sortedDays, now: now, count: 7)),
            last30Days: summarize(days: daysWithinWindow(sortedDays, now: now, count: 30)),
            allTime: summarize(days: sortedDays),
            topModels: makeTopModels(from: modelUsage),
            warnings: warnings
        )
    }

    private func sessionFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "jsonl" else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true ? url : nil
        }
        .sorted { $0.path < $1.path }
    }

    private func scanFile(_ fileURL: URL) throws -> FileScanResult {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var result = FileScanResult()
        var previousTotals: TokenBreakdown?
        var currentModel: String?
        var lastActivityMilliseconds: Int64?
        var seenRunTimestamps = Set<Int64>()
        var firstDayKey: String?
        var fileHadUsage = false

        for line in content.split(whereSeparator: \.isNewline) {
            guard line.utf8.count <= maxLineBytes,
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            let timestampMilliseconds = readTimestampMilliseconds(from: object)
            if firstDayKey == nil, let timestampMilliseconds {
                firstDayKey = dayKey(forMilliseconds: timestampMilliseconds)
            }

            let entryType = stringValue(object["type"]) ?? ""
            let payload = object["payload"] as? [String: Any]
            let payloadType = stringValue(payload?["type"])

            if entryType == "turn_context" {
                currentModel = extractModel(from: payload) ?? currentModel
                continue
            }

            if entryType == "event_msg" || entryType.isEmpty {
                if let rateLimits = extractRateLimits(from: payload, timestampMilliseconds: timestampMilliseconds) {
                    if result.latestRateLimits == nil || rateLimits.updatedAt > result.latestRateLimits!.updatedAt {
                        result.latestRateLimits = rateLimits
                    }
                }

                if payloadType == "agent_message" || payloadType == "agent_reasoning" {
                    if let timestampMilliseconds {
                        trackActivity(
                            timestampMilliseconds: timestampMilliseconds,
                            lastActivityMilliseconds: &lastActivityMilliseconds,
                            daily: &result.dailyUsage
                        )
                    }

                    if payloadType == "agent_message",
                       let timestampMilliseconds,
                       seenRunTimestamps.insert(timestampMilliseconds).inserted {
                        addRun(timestampMilliseconds: timestampMilliseconds, daily: &result.dailyUsage)
                        fileHadUsage = true
                    }

                    continue
                }

                guard payloadType == "token_count" else {
                    continue
                }

                let info = payload?["info"] as? [String: Any]
                let usageRead = readUsage(from: info)
                guard var usage = usageRead.usage else {
                    continue
                }

                if usageRead.isTotal {
                    let previous = previousTotals ?? TokenBreakdown()
                    usage = TokenBreakdown(
                        inputTokens: max(0, usage.inputTokens - previous.inputTokens),
                        cachedInputTokens: max(0, usage.cachedInputTokens - previous.cachedInputTokens),
                        outputTokens: max(0, usage.outputTokens - previous.outputTokens),
                        reasoningOutputTokens: max(0, usage.reasoningOutputTokens - previous.reasoningOutputTokens)
                    )
                    previousTotals = usageRead.usage
                } else {
                    var nextTotals = previousTotals ?? TokenBreakdown()
                    nextTotals.add(usage)
                    previousTotals = nextTotals
                }

                usage.cachedInputTokens = min(usage.cachedInputTokens, usage.inputTokens)
                guard usage.totalTokens > 0 || usage.cachedInputTokens > 0 else {
                    continue
                }

                if let timestampMilliseconds,
                   let key = dayKey(forMilliseconds: timestampMilliseconds) {
                    addUsage(usage, dayKey: key, daily: &result.dailyUsage)
                    let model = currentModel
                        ?? extractModel(from: info)
                        ?? extractModel(from: payload)
                        ?? extractModel(from: object)
                        ?? "unknown"
                    addModelUsage(usage, model: model, dayKey: key, daily: &result.dailyUsage)
                    result.modelUsage[model, default: TokenBreakdown()].add(usage)
                    fileHadUsage = true
                }

                if let timestampMilliseconds {
                    trackActivity(
                        timestampMilliseconds: timestampMilliseconds,
                        lastActivityMilliseconds: &lastActivityMilliseconds,
                        daily: &result.dailyUsage
                    )
                }

                continue
            }

            if entryType == "response_item" {
                let role = stringValue(payload?["role"]) ?? ""
                if role == "assistant",
                   let timestampMilliseconds,
                   seenRunTimestamps.insert(timestampMilliseconds).inserted {
                    addRun(timestampMilliseconds: timestampMilliseconds, daily: &result.dailyUsage)
                    fileHadUsage = true
                }

                if let timestampMilliseconds {
                    trackActivity(
                        timestampMilliseconds: timestampMilliseconds,
                        lastActivityMilliseconds: &lastActivityMilliseconds,
                        daily: &result.dailyUsage
                    )
                }
            }
        }

        if fileHadUsage, let firstDayKey {
            result.dailyUsage[firstDayKey, default: DailyUsage(dayKey: firstDayKey)].sessions += 1
        }

        return result
    }

    private func readUsage(from info: [String: Any]?) -> (usage: TokenBreakdown?, isTotal: Bool) {
        guard let info else {
            return (nil, false)
        }

        if let total = firstDictionary(in: info, keys: ["total_token_usage", "totalTokenUsage"]) {
            return (usageFromDictionary(total), true)
        }

        if let last = firstDictionary(in: info, keys: ["last_token_usage", "lastTokenUsage"]) {
            return (usageFromDictionary(last), false)
        }

        return (nil, false)
    }

    private func usageFromDictionary(_ dictionary: [String: Any]) -> TokenBreakdown {
        TokenBreakdown(
            inputTokens: int64Value(dictionary["input_tokens"] ?? dictionary["inputTokens"]),
            cachedInputTokens: int64Value(
                dictionary["cached_input_tokens"]
                    ?? dictionary["cache_read_input_tokens"]
                    ?? dictionary["cachedInputTokens"]
                    ?? dictionary["cacheReadInputTokens"]
            ),
            outputTokens: int64Value(dictionary["output_tokens"] ?? dictionary["outputTokens"]),
            reasoningOutputTokens: int64Value(dictionary["reasoning_output_tokens"] ?? dictionary["reasoningOutputTokens"])
        )
    }

    private func extractRateLimits(
        from payload: [String: Any]?,
        timestampMilliseconds: Int64?
    ) -> RateLimitSnapshot? {
        guard let rateLimits = payload?["rate_limits"] as? [String: Any]
                ?? payload?["rateLimits"] as? [String: Any]
        else {
            return nil
        }

        let updatedAt = timestampMilliseconds.map(dateFromMilliseconds) ?? Date()
        return RateLimitSnapshot(
            updatedAt: updatedAt,
            primary: rateLimitWindow(from: rateLimits["primary"] as? [String: Any]),
            secondary: rateLimitWindow(from: rateLimits["secondary"] as? [String: Any]),
            credits: creditsSnapshot(from: rateLimits["credits"] as? [String: Any]),
            planType: stringValue(rateLimits["plan_type"] ?? rateLimits["planType"])
        )
    }

    private func rateLimitWindow(from dictionary: [String: Any]?) -> RateLimitWindow? {
        guard let dictionary else {
            return nil
        }

        let used = doubleValue(dictionary["used_percent"] ?? dictionary["usedPercent"])
        let remaining = doubleValue(dictionary["remaining_percent"] ?? dictionary["remainingPercent"] ?? dictionary["remaining"])
        let usedPercent: Double
        if let used {
            usedPercent = min(max(used, 0), 100)
        } else if let remaining {
            usedPercent = min(max(100 - remaining, 0), 100)
        } else {
            return nil
        }

        return RateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: doubleValue(
                dictionary["window_minutes"]
                    ?? dictionary["window_mins"]
                    ?? dictionary["windowDurationMins"]
                    ?? dictionary["window_duration_mins"]
            ),
            resetsAt: dateValue(dictionary["resets_at"] ?? dictionary["resetsAt"])
        )
    }

    private func creditsSnapshot(from dictionary: [String: Any]?) -> CreditsSnapshot? {
        guard let dictionary else {
            return nil
        }

        let unlimited = boolValue(dictionary["unlimited"]) ?? false
        let balance = stringValue(dictionary["balance"])
        let inferredHasCredits = unlimited || (balance.flatMap(Double.init).map { $0 > 0 } ?? false)
        let hasCredits = boolValue(dictionary["has_credits"] ?? dictionary["hasCredits"])
            ?? inferredHasCredits

        return CreditsSnapshot(
            hasCredits: hasCredits,
            unlimited: unlimited,
            balance: balance
        )
    }

    private func readAuthAccount() -> AccountSnapshot? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = stringValue(tokens["idToken"] ?? tokens["id_token"]),
              let payload = decodeJWTPayload(idToken)
        else {
            return nil
        }

        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        let email = stringValue(payload["email"] ?? profile?["email"])?.nonEmpty
        let plan = stringValue(auth?["chatgpt_plan_type"] ?? payload["chatgpt_plan_type"])?.nonEmpty

        guard email != nil || plan != nil else {
            return nil
        }

        return AccountSnapshot(email: email, planType: plan)
    }

    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        var payload = String(parts[1])
        payload = payload.replacingOccurrences(of: "-", with: "+")
        payload = payload.replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload.append(String(repeating: "=", count: padding))

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object
    }

    private func summarize(days: [DailyUsage]) -> UsageWindowSummary {
        var usage = TokenBreakdown()
        var activeMilliseconds: Int64 = 0
        var runs = 0
        var sessions = 0
        var modelUsage = [String: TokenBreakdown]()

        for day in days {
            usage.add(day.usage)
            activeMilliseconds += day.activeMilliseconds
            runs += day.runs
            sessions += day.sessions
            merge(day.modelUsage, into: &modelUsage)
        }

        let costSummary = estimateCost(for: modelUsage)
        return UsageWindowSummary(
            usage: usage,
            activeMilliseconds: activeMilliseconds,
            runs: runs,
            sessions: sessions,
            estimatedCost: costSummary.cost,
            unpricedTokens: costSummary.unpricedTokens
        )
    }

    private func makeTopModels(from usageByModel: [String: TokenBreakdown]) -> [ModelUsage] {
        usageByModel
            .map { model, usage in
                let pricing = PricingCatalog.pricing(for: model)
                return ModelUsage(
                    model: model,
                    usage: usage,
                    estimatedCost: pricing?.estimateCost(for: usage) ?? 0,
                    hasKnownPricing: pricing != nil
                )
            }
            .filter { $0.usage.totalTokens > 0 && $0.model != "unknown" }
            .sorted { $0.usage.totalTokens > $1.usage.totalTokens }
            .prefix(6)
            .map { $0 }
    }

    private func estimateCost(for usageByModel: [String: TokenBreakdown]) -> (cost: Double, unpricedTokens: Int64) {
        usageByModel.reduce(into: (cost: 0.0, unpricedTokens: Int64(0))) { partial, item in
            let pricing = PricingCatalog.pricing(for: item.key)
            if let pricing {
                partial.cost += pricing.estimateCost(for: item.value)
            } else {
                partial.unpricedTokens += item.value.totalTokens
            }
        }
    }

    private func makeRecentDays(from daily: [String: DailyUsage], now: Date, count: Int) -> [DailyUsage] {
        (0..<count).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let key = dayKey(for: date)
            return daily[key] ?? DailyUsage(dayKey: key)
        }
    }

    private func daysWithinWindow(_ days: [DailyUsage], now: Date, count: Int) -> [DailyUsage] {
        let keys = Set(makeRecentDays(from: [:], now: now, count: count).map(\.dayKey))
        return days.filter { keys.contains($0.dayKey) }
    }

    private func addUsage(_ usage: TokenBreakdown, dayKey: String, daily: inout [String: DailyUsage]) {
        daily[dayKey, default: DailyUsage(dayKey: dayKey)].usage.add(usage)
    }

    private func addModelUsage(
        _ usage: TokenBreakdown,
        model: String,
        dayKey: String,
        daily: inout [String: DailyUsage]
    ) {
        daily[dayKey, default: DailyUsage(dayKey: dayKey)].modelUsage[model, default: TokenBreakdown()].add(usage)
    }

    private func addRun(timestampMilliseconds: Int64, daily: inout [String: DailyUsage]) {
        guard let key = dayKey(forMilliseconds: timestampMilliseconds) else {
            return
        }
        daily[key, default: DailyUsage(dayKey: key)].runs += 1
    }

    private func trackActivity(
        timestampMilliseconds: Int64,
        lastActivityMilliseconds: inout Int64?,
        daily: inout [String: DailyUsage]
    ) {
        if let lastActivityMilliseconds {
            let delta = timestampMilliseconds - lastActivityMilliseconds
            if delta > 0, delta <= maxActivityGapMilliseconds,
               let key = dayKey(forMilliseconds: timestampMilliseconds) {
                daily[key, default: DailyUsage(dayKey: key)].activeMilliseconds += delta
            }
        }
        lastActivityMilliseconds = timestampMilliseconds
    }

    private func merge(_ incoming: [String: DailyUsage], into daily: inout [String: DailyUsage]) {
        for (key, value) in incoming {
            daily[key, default: DailyUsage(dayKey: key)].usage.add(value.usage)
            merge(value.modelUsage, into: &daily[key, default: DailyUsage(dayKey: key)].modelUsage)
            daily[key, default: DailyUsage(dayKey: key)].activeMilliseconds += value.activeMilliseconds
            daily[key, default: DailyUsage(dayKey: key)].runs += value.runs
            daily[key, default: DailyUsage(dayKey: key)].sessions += value.sessions
        }
    }

    private func merge(_ incoming: [String: TokenBreakdown], into usageByModel: inout [String: TokenBreakdown]) {
        for (model, usage) in incoming {
            usageByModel[model, default: TokenBreakdown()].add(usage)
        }
    }

    private func firstDictionary(in dictionary: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dictionary[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    private func extractModel(from dictionary: [String: Any]?) -> String? {
        guard let dictionary else {
            return nil
        }

        let info = dictionary["info"] as? [String: Any]
        return stringValue(dictionary["model"] ?? dictionary["model_name"])
            ?? stringValue(info?["model"] ?? info?["model_name"])
    }

    private func readTimestampMilliseconds(from dictionary: [String: Any]) -> Int64? {
        let value = dictionary["timestamp"]
        if let text = stringValue(value) {
            return milliseconds(fromTimestampText: text)
        }
        if let number = int64ValueIfPresent(value) {
            return number > 0 && number < 1_000_000_000_000 ? number * 1000 : number
        }
        return nil
    }

    private func milliseconds(fromTimestampText text: String) -> Int64? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]

        if let date = withFractionalSeconds.date(from: text)
            ?? withoutFractionalSeconds.date(from: text) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let text = stringValue(value),
           let milliseconds = milliseconds(fromTimestampText: text) {
            return dateFromMilliseconds(milliseconds)
        }
        guard let raw = int64ValueIfPresent(value) else {
            return nil
        }
        let milliseconds = raw > 0 && raw < 1_000_000_000_000 ? raw * 1000 : raw
        return dateFromMilliseconds(milliseconds)
    }

    private func dateFromMilliseconds(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private func dayKey(forMilliseconds milliseconds: Int64) -> String? {
        dayKey(for: dateFromMilliseconds(milliseconds))
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

private struct FileScanResult {
    var dailyUsage = [String: DailyUsage]()
    var modelUsage = [String: TokenBreakdown]()
    var latestRateLimits: RateLimitSnapshot?
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func stringValue(_ value: Any?) -> String? {
    switch value {
    case let string as String:
        return string
    case let number as NSNumber:
        return number.stringValue
    default:
        return nil
    }
}

private func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
        return bool
    case let number as NSNumber:
        return number.boolValue
    case let string as String:
        if string.caseInsensitiveCompare("true") == .orderedSame {
            return true
        }
        if string.caseInsensitiveCompare("false") == .orderedSame {
            return false
        }
        return nil
    default:
        return nil
    }
}

private func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let double as Double:
        return double.isFinite ? double : nil
    case let int as Int:
        return Double(int)
    case let int64 as Int64:
        return Double(int64)
    case let number as NSNumber:
        let value = number.doubleValue
        return value.isFinite ? value : nil
    case let string as String:
        let value = Double(string)
        return value?.isFinite == true ? value : nil
    default:
        return nil
    }
}

private func int64Value(_ value: Any?) -> Int64 {
    int64ValueIfPresent(value) ?? 0
}

private func int64ValueIfPresent(_ value: Any?) -> Int64? {
    switch value {
    case let int as Int:
        return Int64(int)
    case let int64 as Int64:
        return int64
    case let double as Double:
        return double.isFinite ? Int64(double) : nil
    case let number as NSNumber:
        return number.int64Value
    case let string as String:
        if let parsed = Int64(string) {
            return parsed
        }
        if let parsed = Double(string) {
            return Int64(parsed)
        }
        return nil
    default:
        return nil
    }
}
