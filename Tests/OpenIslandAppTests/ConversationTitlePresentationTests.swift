import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

struct ConversationTitlePresentationTests {
    private func session(conversationTitle: String?) -> AgentSession {
        var session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Done",
            updatedAt: Date.now.addingTimeInterval(-30),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "worktree",
                paneTitle: "codex ~/tmp/worktree",
                workingDirectory: "/tmp/worktree",
                terminalSessionID: "ghostty-1"
            ),
            codexMetadata: CodexSessionMetadata(
                initialUserPrompt: "Commit the README change.",
                lastUserPrompt: "Also confirm the worktree status."
            )
        )
        session.conversationTitle = conversationTitle
        return session
    }

    @Test
    func headlinePrefersTheRecordedConversationTitle() {
        #expect(session(conversationTitle: "整理 README 提交").spotlightHeadlineText == "worktree · 整理 README 提交")
    }

    @Test
    func headlineFallsBackToTheInitialPrompt() {
        #expect(session(conversationTitle: nil).spotlightHeadlineText == "worktree · Commit the README change.")
        #expect(session(conversationTitle: "  ").spotlightHeadlineText == "worktree · Commit the README change.")
    }
}
