import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

struct UnknownTerminalBadgeTests {
    private func session(terminalApp: String?) -> AgentSession {
        AgentSession(
            id: "session-1",
            title: "Claude · Desktop",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .stale,
            phase: .completed,
            summary: "Done",
            updatedAt: Date(timeIntervalSince1970: 10_000),
            jumpTarget: terminalApp.map {
                JumpTarget(
                    terminalApp: $0,
                    workspaceName: "Desktop",
                    paneTitle: "claude ~/Desktop",
                    workingDirectory: "/tmp/Desktop"
                )
            }
        )
    }

    @Test
    func knownTerminalShowsBadge() {
        #expect(session(terminalApp: "Ghostty").spotlightTerminalBadge == "Ghostty")
    }

    @Test
    func unknownOrBlankTerminalHidesBadge() {
        #expect(session(terminalApp: "Unknown").spotlightTerminalBadge == nil)
        #expect(session(terminalApp: "unknown").spotlightTerminalBadge == nil)
        #expect(session(terminalApp: "  ").spotlightTerminalBadge == nil)
        #expect(session(terminalApp: nil).spotlightTerminalBadge == nil)
    }

    @Test
    func syntheticSummaryOmitsUnknownTerminal() {
        #expect(ProcessMonitoringCoordinator.syntheticDetectedSummary(subject: "Claude session", terminalApp: "Ghostty")
            == "Claude session detected from Ghostty.")
        #expect(ProcessMonitoringCoordinator.syntheticDetectedSummary(subject: "Claude session", terminalApp: "Unknown")
            == "Claude session detected.")
        #expect(ProcessMonitoringCoordinator.syntheticDetectedSummary(subject: "Cursor agent", terminalApp: " ")
            == "Cursor agent detected.")
    }
}
