import Foundation

/// One PI Desktop conversation as the island displays it.
///
/// Two producers feed this type: the read-only SQLite reader (default) and the
/// optional PI Desktop plugin, which can push a snapshot the moment a turn
/// starts. Both must produce the same shape so the bridge and the reducer never
/// care which one is alive.
public struct PiDesktopSessionSnapshot: Equatable, Codable, Sendable {
    public var sessionID: String
    public var title: String
    public var projectPath: String?
    public var workspaceName: String?
    public var providerID: String?
    public var modelID: String?
    /// `agent` or `chat`.
    public var mode: String
    /// `ask`, `accept-edits`, `auto`, or `inherit`.
    public var permissionMode: String
    /// PI Desktop's `title_source`: legacy | default | manual | generated.
    public var titleSource: String
    public var phase: SessionPhase
    public var summary: String?
    /// Tool name of the most recent tool message, e.g. `Bash`.
    public var currentTool: String?
    public var todoCompleted: Int
    public var todoTotal: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        sessionID: String,
        title: String,
        projectPath: String? = nil,
        workspaceName: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        mode: String = "agent",
        permissionMode: String = "inherit",
        titleSource: String = "legacy",
        phase: SessionPhase = .completed,
        summary: String? = nil,
        currentTool: String? = nil,
        todoCompleted: Int = 0,
        todoTotal: Int = 0,
        createdAt: Date = .distantPast,
        updatedAt: Date = .distantPast
    ) {
        self.sessionID = sessionID
        self.title = title
        self.projectPath = projectPath
        self.workspaceName = workspaceName
        self.providerID = providerID
        self.modelID = modelID
        self.mode = mode
        self.permissionMode = permissionMode
        self.titleSource = titleSource
        self.phase = phase
        self.summary = summary
        self.currentTool = currentTool
        self.todoCompleted = todoCompleted
        self.todoTotal = todoTotal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(record: PiDesktopSessionRecord) {
        self.init(
            sessionID: record.id,
            title: record.title,
            projectPath: record.projectPath,
            workspaceName: record.workspaceName,
            providerID: record.providerID,
            modelID: record.modelID,
            mode: record.mode,
            permissionMode: record.permissionMode,
            titleSource: record.titleSource,
            phase: record.phase,
            summary: record.lastAssistantLine,
            currentTool: record.currentTool,
            todoCompleted: record.todoCompleted,
            todoTotal: record.todoTotal,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }
}

/// Local-day token ledger for PI Desktop, mirroring `DSHTodayTokens`.
public struct PiDesktopTodayTokens: Equatable, Codable, Sendable {
    public var totalTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var sessionCount: Int

    public init(
        totalTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        sessionCount: Int = 0
    ) {
        self.totalTokens = max(0, totalTokens)
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.sessionCount = max(0, sessionCount)
    }

    public static let zero = PiDesktopTodayTokens()

    /// Sums today's turns. Turns are keyed by id first: a resumed or retried
    /// turn can appear twice in one window, and counting it twice would inflate
    /// the chip with no way to notice.
    public init(turns: [PiDesktopTurnUsage]) {
        var seen: Set<String> = []
        var unique: [PiDesktopTurnUsage] = []
        unique.reserveCapacity(turns.count)
        for turn in turns where seen.insert(turn.id).inserted {
            unique.append(turn)
        }

        let input = unique.reduce(0) { $0 + $1.inputTokens }
        let output = unique.reduce(0) { $0 + $1.outputTokens }
        self.init(
            totalTokens: input + output,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: unique.reduce(0) { $0 + $1.cacheReadTokens },
            sessionCount: Set(unique.map(\.sessionID)).count
        )
    }
}

/// Commands sent by the `open-island-pi-desktop.js` plugin.
public struct PiDesktopHookPayload: Equatable, Codable, Sendable {
    public enum Event: String, Codable, Sendable {
        /// Periodic full snapshot; also the catch-up path after a late launch.
        case snapshot
        case sessionStart
        case activity
        /// Approval/question state changed. The plugin cannot answer, so this
        /// only raises attention; see docs/exec-plans/active for the limits.
        case approval
        case sessionEnd
    }

    public var event: Event
    public var session: PiDesktopSessionSnapshot?
    public var sessions: [PiDesktopSessionSnapshot]?
    public var todayTokens: PiDesktopTodayTokens?
    public var timestamp: Date

    public init(
        event: Event,
        session: PiDesktopSessionSnapshot? = nil,
        sessions: [PiDesktopSessionSnapshot]? = nil,
        todayTokens: PiDesktopTodayTokens? = nil,
        timestamp: Date = .now
    ) {
        self.event = event
        self.session = session
        self.sessions = sessions
        self.todayTokens = todayTokens
        self.timestamp = timestamp
    }
}

public struct PiDesktopTodayTokensUpdated: Equatable, Codable, Sendable {
    public var usage: PiDesktopTodayTokens
    public var timestamp: Date

    public init(usage: PiDesktopTodayTokens, timestamp: Date = .now) {
        self.usage = usage
        self.timestamp = timestamp
    }
}
