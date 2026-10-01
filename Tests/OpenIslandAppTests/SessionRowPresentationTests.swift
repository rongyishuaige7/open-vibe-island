import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

struct SessionRowPresentationTests {
    private static let zh = SessionTextLocalizer { key in
        key == SessionTextLocalizer.promptLineKey ? "你：%@" : nil
    }

    private func rowSession(
        tool: AgentTool = .codex,
        workspace: String = "worktree",
        workingDirectory: String = "/tmp/worktree",
        terminalApp: String = "Ghostty",
        initialPrompt: String? = "Commit the README change.",
        latestPrompt: String? = "Also confirm the worktree status.",
        conversationTitle: String? = nil,
        model: String? = nil,
        worktreeBranch: String? = nil,
        updatedAt: Date = Date.now.addingTimeInterval(-30)
    ) -> AgentSession {
        var session = AgentSession(
            id: "session-1",
            title: "\(tool.displayName) · \(workspace)",
            tool: tool,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Done",
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(
                terminalApp: terminalApp,
                workspaceName: workspace,
                paneTitle: "\(tool.shortName.lowercased()) \(workingDirectory)",
                workingDirectory: workingDirectory,
                terminalSessionID: "terminal-1"
            )
        )
        if tool == .claudeCode {
            session.claudeMetadata = ClaudeSessionMetadata(
                initialUserPrompt: initialPrompt,
                lastUserPrompt: latestPrompt,
                model: model,
                worktreeBranch: worktreeBranch
            )
        } else {
            session.codexMetadata = CodexSessionMetadata(
                initialUserPrompt: initialPrompt,
                lastUserPrompt: latestPrompt,
                model: model
            )
        }
        session.conversationTitle = conversationTitle
        return session
    }

    // MARK: - Line 1: topic

    @Test
    func topicLeadsWithTheRecordedTitleAndTheWorkspaceMovesToLineTwo() {
        let session = rowSession(conversationTitle: "整理 README 提交")
        #expect(session.spotlightRowTopicText == "整理 README 提交")
        #expect(session.spotlightRowContextLine(.english, includesPrompt: true)
            == "worktree · You: Also confirm the worktree status.")
    }

    @Test
    func topicFallsBackToTheFirstPromptThenTheLatestThenTheWorkspace() {
        #expect(rowSession().spotlightRowTopicText == "Commit the README change.")
        #expect(rowSession(conversationTitle: "  ").spotlightRowTopicText == "Commit the README change.")
        #expect(rowSession(initialPrompt: nil).spotlightRowTopicText == "Also confirm the worktree status.")

        let bare = rowSession(initialPrompt: nil, latestPrompt: nil)
        #expect(bare.spotlightRowTopicText == "worktree")
        #expect(bare.spotlightRowWorkspaceText == nil)
        #expect(bare.spotlightRowContextLine(.english, includesPrompt: true) == nil)
    }

    // MARK: - Line 2: workspace · prompt

    @Test
    func lineTwoSkipsAPromptThatIsAlreadyTheTopic() {
        let single = rowSession(latestPrompt: "Commit the README change.")
        #expect(single.spotlightRowTopicText == "Commit the README change.")
        #expect(single.spotlightRowContextLine(.english, includesPrompt: true) == "worktree")
    }

    @Test
    func lineTwoKeepsOnlyTheWorkspaceWhenThePromptIsExcluded() {
        #expect(rowSession().spotlightRowContextLine(.english, includesPrompt: false) == "worktree")
    }

    @Test
    func rootWorkspaceStaysOffTheRow() {
        let root = rowSession(workspace: "/", workingDirectory: "/")
        #expect(root.spotlightRowWorkspaceText == nil)
        #expect(root.spotlightRowContextLine(.english, includesPrompt: true)
            == "You: Also confirm the worktree status.")

        let bare = rowSession(workspace: "/", workingDirectory: "/", initialPrompt: nil, latestPrompt: nil)
        #expect(bare.spotlightRowTopicText == "/")
    }

    @Test
    func worktreeBranchRidesWithTheWorkspaceInTheAppLanguage() {
        let session = rowSession(
            tool: .claudeCode,
            conversationTitle: "Polish the island rows",
            worktreeBranch: "feat/polish"
        )
        #expect(session.spotlightRowWorkspaceText == "worktree (feat/polish)")
        #expect(session.spotlightRowContextLine(Self.zh, includesPrompt: true)
            == "worktree (feat/polish) · 你：Also confirm the worktree status.")
    }

    // MARK: - Badge

    @Test
    func badgeShowsTheModelAndFallsBackToTheAgentName() {
        #expect(rowSession(tool: .claudeCode, model: "claude-opus-5-5").spotlightAgentBadgeTitle == "Opus 5.5")
        #expect(rowSession(model: "gpt-5.1-codex").spotlightAgentBadgeTitle == "gpt-5.1-codex")
        #expect(rowSession(tool: .claudeCode).spotlightAgentBadgeTitle == "claude")
        #expect(rowSession().spotlightAgentBadgeTitle == "codex")
        #expect(rowSession(tool: .claudeCode, model: "<synthetic>").spotlightAgentBadgeTitle == "claude")
    }

    @Test
    func badgeHelpNamesTheAgentTheModelAndTheTerminal() {
        #expect(rowSession(tool: .claudeCode, model: "claude-opus-5-5").spotlightAgentBadgeHelp
            == "Claude Code · claude-opus-5-5 · Ghostty")
        #expect(rowSession(terminalApp: "Unknown").spotlightAgentBadgeHelp == "Codex")
        #expect(rowSession(tool: .claudeCode, model: "<synthetic>").spotlightAgentBadgeHelp
            == "Claude Code · Ghostty")
    }

    // MARK: - Height estimate

    @Test
    func unseenFinishKeepsItsLineTwoInTheHeightEstimate() {
        let old = rowSession(updatedAt: Date.now.addingTimeInterval(-3_600))
        #expect(old.estimatedIslandRowHeight(at: .now) == 40)
        // Past the age cutoff line 2 is just the workspace; the activity line stays hidden.
        #expect(old.estimatedIslandRowHeight(at: .now, isUnseenCompletion: true) == 57)
    }
}
