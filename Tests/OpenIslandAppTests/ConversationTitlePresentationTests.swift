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
        #expect(session(conversationTitle: "整理 README 提交").spotlightHeadlineText == "整理 README 提交 · worktree")
    }

    @Test
    func headlineFallsBackToTheInitialPrompt() {
        #expect(session(conversationTitle: nil).spotlightHeadlineText == "Commit the README change. · worktree")
        #expect(session(conversationTitle: "  ").spotlightHeadlineText == "Commit the README change. · worktree")
    }

    private func claudeSession(conversationTitle: String?, workspace: String = "video-making2") -> AgentSession {
        var session = AgentSession(
            id: "claude-1",
            title: "Claude · \(workspace)",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Claude session",
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Unknown",
                workspaceName: workspace,
                paneTitle: "claude claude-1",
                workingDirectory: "/Users/user/\(workspace)"
            ),
            claudeMetadata: ClaudeSessionMetadata(
                initialUserPrompt: "制作Yi盘15秒品牌宣传动画",
                lastUserPrompt: "继续优化画面"
            )
        )
        session.conversationTitle = conversationTitle
        return session
    }

    @Test
    func claudeHeadlineShowsTitleFirstAndWorkspaceSecond() {
        let session = claudeSession(conversationTitle: "Yi盘15秒品牌宣传片")
        #expect(session.spotlightHeadlineText == "Yi盘15秒品牌宣传片 · video-making2")
    }

    @Test
    func claudeHeadlineFallsBackToPromptWhenNoTitle() {
        let session = claudeSession(conversationTitle: nil)
        #expect(session.spotlightHeadlineText == "制作Yi盘15秒品牌宣传动画 · video-making2")
    }

    private func agySession(conversationTitle: String?, workspace: String = "Desktop", branch: String? = nil) -> AgentSession {
        var session = AgentSession(
            id: "agy-1",
            title: "新会话 · \(workspace)",
            tool: .geminiCLI,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Antigravity session",
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Antigravity",
                workspaceName: workspace,
                paneTitle: "agy agy-1",
                workingDirectory: "/Users/user/\(workspace)"
            )
        )
        session.conversationTitle = conversationTitle
        return session
    }

    @Test
    func agyHeadlineShowsTitleFirstAndWorkspaceSecond() {
        let session = agySession(conversationTitle: "状态指示异常排查")
        #expect(session.spotlightHeadlineText == "状态指示异常排查 · Desktop")
    }

    @Test
    func agyHeadlineFallsBackToNewSessionWhenTitleEmpty() {
        let session = agySession(conversationTitle: nil)
        #expect(session.spotlightHeadlineText == "新会话 · Desktop")

        let emptySession = agySession(conversationTitle: "   ")
        #expect(emptySession.spotlightHeadlineText == "新会话 · Desktop")
    }
}
