import Foundation

public struct TokenBreakdown: Equatable, Sendable {
    public var inputTokens: Int64
    public var cachedInputTokens: Int64
    public var outputTokens: Int64
    public var reasoningOutputTokens: Int64

    public init(
        inputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    public var totalTokens: Int64 {
        inputTokens + outputTokens
    }

    public var uncachedInputTokens: Int64 {
        max(0, inputTokens - cachedInputTokens)
    }

    public mutating func add(_ other: TokenBreakdown) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
    }
}

public struct DailyUsage: Identifiable, Equatable, Sendable {
    public var dayKey: String
    public var usage: TokenBreakdown
    public var modelUsage: [String: TokenBreakdown]
    public var activeMilliseconds: Int64
    public var runs: Int
    public var sessions: Int

    public init(
        dayKey: String,
        usage: TokenBreakdown = TokenBreakdown(),
        modelUsage: [String: TokenBreakdown] = [:],
        activeMilliseconds: Int64 = 0,
        runs: Int = 0,
        sessions: Int = 0
    ) {
        self.dayKey = dayKey
        self.usage = usage
        self.modelUsage = modelUsage
        self.activeMilliseconds = activeMilliseconds
        self.runs = runs
        self.sessions = sessions
    }

    public var id: String {
        dayKey
    }
}

public struct UsageWindowSummary: Equatable, Sendable {
    public var usage: TokenBreakdown
    public var activeMilliseconds: Int64
    public var runs: Int
    public var sessions: Int
    public var estimatedCost: Double
    public var unpricedTokens: Int64

    public init(
        usage: TokenBreakdown = TokenBreakdown(),
        activeMilliseconds: Int64 = 0,
        runs: Int = 0,
        sessions: Int = 0,
        estimatedCost: Double = 0,
        unpricedTokens: Int64 = 0
    ) {
        self.usage = usage
        self.activeMilliseconds = activeMilliseconds
        self.runs = runs
        self.sessions = sessions
        self.estimatedCost = estimatedCost
        self.unpricedTokens = unpricedTokens
    }

    public var cacheHitRate: Double {
        guard usage.inputTokens > 0 else { return 0 }
        return Double(usage.cachedInputTokens) / Double(usage.inputTokens)
    }
}

public struct ModelUsage: Identifiable, Equatable, Sendable {
    public var model: String
    public var usage: TokenBreakdown
    public var estimatedCost: Double
    public var hasKnownPricing: Bool

    public init(
        model: String,
        usage: TokenBreakdown,
        estimatedCost: Double,
        hasKnownPricing: Bool
    ) {
        self.model = model
        self.usage = usage
        self.estimatedCost = estimatedCost
        self.hasKnownPricing = hasKnownPricing
    }

    public var id: String {
        model
    }
}

public struct RateLimitWindow: Equatable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Double?
    public var resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Double?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

public struct CreditsSnapshot: Equatable, Sendable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct RateLimitSnapshot: Equatable, Sendable {
    public var updatedAt: Date
    public var primary: RateLimitWindow?
    public var secondary: RateLimitWindow?
    public var credits: CreditsSnapshot?
    public var planType: String?

    public init(
        updatedAt: Date,
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?,
        credits: CreditsSnapshot?,
        planType: String?
    ) {
        self.updatedAt = updatedAt
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.planType = planType
    }
}

public struct AccountSnapshot: Equatable, Sendable {
    public var email: String?
    public var planType: String?

    public init(email: String?, planType: String?) {
        self.email = email
        self.planType = planType
    }
}

public struct UsageSummary: Equatable, Sendable {
    public var codexHome: URL
    public var generatedAt: Date
    public var account: AccountSnapshot?
    public var latestRateLimits: RateLimitSnapshot?
    public var recentDays: [DailyUsage]
    public var allDays: [DailyUsage]
    public var today: UsageWindowSummary
    public var last7Days: UsageWindowSummary
    public var last30Days: UsageWindowSummary
    public var allTime: UsageWindowSummary
    public var topModels: [ModelUsage]
    public var warnings: [String]

    public init(
        codexHome: URL,
        generatedAt: Date,
        account: AccountSnapshot?,
        latestRateLimits: RateLimitSnapshot?,
        recentDays: [DailyUsage],
        allDays: [DailyUsage],
        today: UsageWindowSummary,
        last7Days: UsageWindowSummary,
        last30Days: UsageWindowSummary,
        allTime: UsageWindowSummary,
        topModels: [ModelUsage],
        warnings: [String]
    ) {
        self.codexHome = codexHome
        self.generatedAt = generatedAt
        self.account = account
        self.latestRateLimits = latestRateLimits
        self.recentDays = recentDays
        self.allDays = allDays
        self.today = today
        self.last7Days = last7Days
        self.last30Days = last30Days
        self.allTime = allTime
        self.topModels = topModels
        self.warnings = warnings
    }
}

extension UsageSummary {
    public func topModelsForDays(matching dayKeys: Set<String>, limit: Int = 6) -> [ModelUsage] {
        var modelTokens = [String: TokenBreakdown]()
        for day in allDays where dayKeys.contains(day.dayKey) {
            for (model, usage) in day.modelUsage {
                modelTokens[model, default: TokenBreakdown()].add(usage)
            }
        }
        return modelTokens
            .map { model, usage in
                let pricing = PricingCatalog.pricing(for: model)
                return ModelUsage(
                    model: model, usage: usage,
                    estimatedCost: pricing?.estimateCost(for: usage) ?? 0,
                    hasKnownPricing: pricing != nil
                )
            }
            .filter { $0.usage.totalTokens > 0 && $0.model != "unknown" }
            .sorted { $0.usage.totalTokens > $1.usage.totalTokens }
            .prefix(limit)
            .map { $0 }
    }
}

public struct ModelPricing: Equatable, Sendable {
    public var inputPerMillion: Double
    public var cachedInputPerMillion: Double
    public var outputPerMillion: Double

    public init(
        inputPerMillion: Double,
        cachedInputPerMillion: Double,
        outputPerMillion: Double
    ) {
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    public func estimateCost(for usage: TokenBreakdown) -> Double {
        let uncachedInputCost = Double(usage.uncachedInputTokens) / 1_000_000 * inputPerMillion
        let cachedInputCost = Double(usage.cachedInputTokens) / 1_000_000 * cachedInputPerMillion
        let outputCost = Double(usage.outputTokens) / 1_000_000 * outputPerMillion
        return uncachedInputCost + cachedInputCost + outputCost
    }
}

public enum PricingCatalog {
    public static func pricing(for model: String) -> ModelPricing? {
        let normalized = model.lowercased()

        if normalized.contains("gpt-5.4-nano") {
            return ModelPricing(inputPerMillion: 0.20, cachedInputPerMillion: 0.02, outputPerMillion: 1.25)
        }

        if normalized.contains("gpt-5.4-mini") {
            return ModelPricing(inputPerMillion: 0.75, cachedInputPerMillion: 0.075, outputPerMillion: 4.50)
        }

        if normalized.contains("gpt-5.4") {
            return ModelPricing(inputPerMillion: 2.50, cachedInputPerMillion: 0.25, outputPerMillion: 15.00)
        }

        return nil
    }
}
