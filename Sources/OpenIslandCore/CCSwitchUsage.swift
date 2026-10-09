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

    public static func + (lhs: AgentTokenTotals, rhs: AgentTokenTotals) -> AgentTokenTotals {
        AgentTokenTotals(
            requestCount: lhs.requestCount + rhs.requestCount,
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens
        )
    }

    public static func += (lhs: inout AgentTokenTotals, rhs: AgentTokenTotals) {
        lhs = lhs + rhs
    }
}

/// Claude, Codex, and Antigravity token totals since local midnight.
public struct TodayTokenUsage: Equatable, Sendable {
    public var dayStart: Date
    public var claude: AgentTokenTotals
    public var claudePro: AgentTokenTotals
    public var codex: AgentTokenTotals
    public var agy: AgentTokenTotals
    public var agyPro: AgentTokenTotals
    /// KEEPER usage from any other upstream, e.g. an OpenAI-compatible API key.
    public var other: AgentTokenTotals
    public var agyAccounts: [String]
    public var agyProAccounts: [String]
    public var codexAccounts: [String]
    public var claudeAccounts: [String]
    public var claudeProAccounts: [String]
    public var otherAccounts: [String]
    public var claudeProCostUSD: Double?
    public var claudeProRateLimit5h: Int?
    public var claudeProRateLimit7d: Int?

    public init(
        dayStart: Date,
        claude: AgentTokenTotals = .zero,
        claudePro: AgentTokenTotals = .zero,
        codex: AgentTokenTotals = .zero,
        agy: AgentTokenTotals = .zero,
        agyPro: AgentTokenTotals = .zero,
        other: AgentTokenTotals = .zero,
        agyAccounts: [String] = [],
        agyProAccounts: [String] = [],
        codexAccounts: [String] = [],
        claudeAccounts: [String] = [],
        claudeProAccounts: [String] = [],
        otherAccounts: [String] = [],
        claudeProCostUSD: Double? = nil,
        claudeProRateLimit5h: Int? = nil,
        claudeProRateLimit7d: Int? = nil
    ) {
        self.dayStart = dayStart
        self.claude = claude
        self.claudePro = claudePro
        self.codex = codex
        self.agy = agy
        self.agyPro = agyPro
        self.other = other
        self.agyAccounts = agyAccounts
        self.agyProAccounts = agyProAccounts
        self.codexAccounts = codexAccounts
        self.claudeAccounts = claudeAccounts
        self.claudeProAccounts = claudeProAccounts
        self.otherAccounts = otherAccounts
        self.claudeProCostUSD = claudeProCostUSD
        self.claudeProRateLimit5h = claudeProRateLimit5h
        self.claudeProRateLimit7d = claudeProRateLimit7d
    }

    /// Every channel together, cache included.
    public var totalTokens: Int {
        claude.totalTokens
            + claudePro.totalTokens
            + codex.totalTokens
            + agy.totalTokens
            + agyPro.totalTokens
            + other.totalTokens
    }

    /// Where each total came from: the KEEPER accounts that logged usage
    /// today, plus CC Switch for the agents it proxies. Empty when unknown.
    public var claudeAccountHint: String {
        (claudeAccounts + ["CC Switch"]).joined(separator: ", ")
    }

    public var claudeProAccountHint: String {
        if claudeProAccounts.isEmpty {
            return "Pro"
        }
        return claudeProAccounts.joined(separator: ", ")
    }

    public var codexAccountHint: String {
        (codexAccounts + ["CC Switch"]).joined(separator: ", ")
    }

    public var agyAccountHint: String {
        agyAccounts.joined(separator: ", ")
    }

    public var agyProAccountHint: String {
        agyProAccounts.joined(separator: ", ")
    }

    public var otherAccountHint: String {
        otherAccounts.joined(separator: ", ")
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
