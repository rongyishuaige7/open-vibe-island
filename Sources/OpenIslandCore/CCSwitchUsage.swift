import Foundation

/// Token totals CC Switch logged for one agent over a time range.
public struct AgentTokenTotals: Equatable, Sendable {
    /// Every logged request, failed ones included.
    public var requestCount: Int
    /// Input, output, cache-read and cache-creation tokens together.
    public var totalTokens: Int
    /// The cache-read share of `totalTokens`.
    public var cacheReadTokens: Int

    public init(requestCount: Int = 0, totalTokens: Int = 0, cacheReadTokens: Int = 0) {
        self.requestCount = requestCount
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public static let zero = AgentTokenTotals()
}

/// Claude, Codex, and Antigravity token totals since local midnight.
public struct TodayTokenUsage: Equatable, Sendable {
    public var dayStart: Date
    public var claude: AgentTokenTotals
    public var codex: AgentTokenTotals
    public var agy: AgentTokenTotals
    public var agyPro: AgentTokenTotals

    public init(
        dayStart: Date,
        claude: AgentTokenTotals = .zero,
        codex: AgentTokenTotals = .zero,
        agy: AgentTokenTotals = .zero,
        agyPro: AgentTokenTotals = .zero
    ) {
        self.dayStart = dayStart
        self.claude = claude
        self.codex = codex
        self.agy = agy
        self.agyPro = agyPro
    }
}

public enum CCSwitchUsageError: Error, Equatable, LocalizedError {
    /// CC Switch is not installed, or has not created its database yet.
    case databaseMissing
    /// The database could not be opened or queried: busy, or its schema changed.
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .databaseMissing:
            "CC Switch database not found"
        case let .sqlite(message):
            message
        }
    }
}
