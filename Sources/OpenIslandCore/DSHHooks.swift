import Foundation

/// One live DeepSeek Harness session as published by the Open Island DSH
/// host plugin. The plugin is the only producer: DSH sessions are hosted by
/// the Electron app rather than a per-session CLI process.
public struct DSHSessionSnapshot: Equatable, Codable, Sendable {
    public var sessionID: String
    public var title: String?
    public var cwd: String?
    public var workspaceName: String?
    public var summary: String?
    public var phase: SessionPhase
    public var createdAt: Date?
    public var updatedAt: Date?
    public var parentSessionID: String?
    public var isSubagent: Bool?

    public init(
        sessionID: String,
        title: String? = nil,
        cwd: String? = nil,
        workspaceName: String? = nil,
        summary: String? = nil,
        phase: SessionPhase = .running,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        parentSessionID: String? = nil,
        isSubagent: Bool? = false
    ) {
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.workspaceName = workspaceName
        self.summary = summary
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentSessionID = parentSessionID
        self.isSubagent = isSubagent
    }
}

/// The DSH integration's local-day token ledger. DSH does not route through
/// CC Switch, so the plugin maintains this aggregate beside its session data.
public struct DSHTodayTokens: Equatable, Codable, Sendable {
    public var totalTokens: Int
    public var cacheReadTokens: Int
    public var sessionCount: Int

    public init(totalTokens: Int = 0, cacheReadTokens: Int = 0, sessionCount: Int = 0) {
        self.totalTokens = max(0, totalTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.sessionCount = max(0, sessionCount)
    }

    public static let zero = DSHTodayTokens()
}

/// Commands sent by the `open-island-dsh.mjs` host plugin.
public struct DSHHookPayload: Equatable, Codable, Sendable {
    public enum Event: String, Codable, Sendable {
        /// Periodic full snapshot. Upserts every live session and carries the
        /// local-day token ledger, so a late Open Island launch catches up.
        case snapshot
        case sessionStart
        case activity
        case sessionEnd
    }

    public var event: Event
    public var session: DSHSessionSnapshot?
    public var sessions: [DSHSessionSnapshot]?
    public var todayTokens: DSHTodayTokens?
    public var timestamp: Date

    public init(
        event: Event,
        session: DSHSessionSnapshot? = nil,
        sessions: [DSHSessionSnapshot]? = nil,
        todayTokens: DSHTodayTokens? = nil,
        timestamp: Date = .now
    ) {
        self.event = event
        self.session = session
        self.sessions = sessions
        self.todayTokens = todayTokens ?? .zero
        self.timestamp = timestamp
    }
}

public struct DSHTodayTokensUpdated: Equatable, Codable, Sendable {
    public var usage: DSHTodayTokens
    public var timestamp: Date

    public init(usage: DSHTodayTokens, timestamp: Date = .now) {
        self.usage = usage
        self.timestamp = timestamp
    }
}
