import Foundation

/// Turns a PI Desktop snapshot into the island's normal session events.
///
/// Kept pure and shared on purpose: the SQLite poller and the optional PI
/// Desktop plugin both produce `PiDesktopSessionSnapshot` values, and the two
/// paths must not drift in title, summary or jump-target rules.
public enum PiDesktopEventMapper {
    public static let bundleIdentifier = "net.aiuo.pi-desktop"
    public static let displayName = "PI Desktop"

    public static func title(for snapshot: PiDesktopSessionSnapshot) -> String {
        let title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        if let workspace = snapshot.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines), !workspace.isEmpty {
            return "\(displayName) · \(workspace)"
        }
        if let path = snapshot.projectPath, !path.isEmpty {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty {
                return "\(displayName) · \(name)"
            }
        }
        return displayName
    }

    /// Titles PI Desktop writes before it has anything to name the session
    /// after. The island shows them verbatim, which reads as "new session".
    private static let placeholderTitles: Set<String> = [
        "新会话", "new session", "untitled", "no title", "无标题"
    ]

    /// The topic line the island renders. `spotlightHeadlinePromptText` prefers
    /// `conversationTitle` over any other field, so a snapshot that only sets
    /// `title` still renders as "新会话" for PI Desktop sessions.
    public static func conversationTitle(for snapshot: PiDesktopSessionSnapshot) -> String? {
        let trimmed = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard !placeholderTitles.contains(trimmed.lowercased()) else {
            return nil
        }
        return trimmed
    }

    public static func summary(for snapshot: PiDesktopSessionSnapshot) -> String {
        let detail = snapshot.summary?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch snapshot.phase {
        case .waitingForApproval:
            return detail?.isEmpty == false ? detail! : "\(displayName) is waiting for approval."
        case .waitingForAnswer:
            return detail?.isEmpty == false ? detail! : "\(displayName) is waiting for an answer."
        case .running:
            if let tool = snapshot.currentTool?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty {
                return "Running \(tool)"
            }
            return detail?.isEmpty == false ? detail! : "\(displayName) is working."
        case .completed:
            if let detail, !detail.isEmpty {
                return detail
            }
            return "\(displayName) finished the turn."
        }
    }

    public static func jumpTarget(for snapshot: PiDesktopSessionSnapshot) -> JumpTarget {
        let workspace = snapshot.workspaceName
            ?? snapshot.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? displayName
        return JumpTarget(
            terminalApp: displayName,
            workspaceName: workspace,
            paneTitle: title(for: snapshot),
            workingDirectory: snapshot.projectPath,
            terminalSessionID: snapshot.sessionID
        )
    }

    /// Events for one snapshot: start (or retitle), activity when something
    /// visible changed, plus the heartbeat that keeps the row alive.
    public static func events(
        for snapshot: PiDesktopSessionSnapshot,
        existing: AgentSession?,
        timestamp: Date
    ) -> [AgentEvent] {
        var events: [AgentEvent] = []
        let resolvedTitle = title(for: snapshot)
        let resolvedConversationTitle = conversationTitle(for: snapshot)
        let resolvedSummary = summary(for: snapshot)
        // A session we already ended (app quit, or it dropped out of a
        // snapshot) comes back to life when PI Desktop reports it again.
        let current = existing?.isSessionEnded == true ? nil : existing

        if current == nil
            || current?.title != resolvedTitle
            || current?.conversationTitle != resolvedConversationTitle {
            events.append(
                .sessionStarted(
                    SessionStarted(
                        sessionID: snapshot.sessionID,
                        title: resolvedTitle,
                        conversationTitle: resolvedConversationTitle,
                        tool: .piDesktop,
                        origin: .live,
                        initialPhase: snapshot.phase,
                        summary: resolvedSummary,
                        timestamp: timestamp,
                        jumpTarget: jumpTarget(for: snapshot)
                    )
                )
            )
        } else if current?.phase != snapshot.phase || current?.summary != resolvedSummary {
            events.append(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: snapshot.sessionID,
                        summary: resolvedSummary,
                        phase: snapshot.phase,
                        timestamp: timestamp
                    )
                )
            )
        }

        events.append(
            .sessionHeartbeat(
                SessionHeartbeat(sessionID: snapshot.sessionID, timestamp: timestamp)
            )
        )
        return events
    }

    public static func sessionEnded(
        sessionID: String,
        summary: String? = nil,
        timestamp: Date
    ) -> AgentEvent {
        .sessionCompleted(
            SessionCompleted(
                sessionID: sessionID,
                summary: summary?.isEmpty == false ? summary! : "\(displayName) closed the session.",
                timestamp: timestamp,
                isSessionEnd: true
            )
        )
    }
}
