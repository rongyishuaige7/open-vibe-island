import Foundation
import OpenIslandCore

enum SpotlightActivityTone {
    case live
    case idle
    case ready
    case attention
}

enum IslandSessionPresence: Equatable {
    case running
    case active
    case inactive
}

extension AgentSession {
    private static let collapsedDetailAgeThreshold: TimeInterval = 20 * 60
    private static let islandActivityThreshold: TimeInterval = 20 * 60
    static let staleCompletedDisplayThreshold: TimeInterval = 5 * 60

    /// Whether this session represents a subagent (worktree agent) that should
    /// not appear as a separate entry in the session list.  The parent session
    /// already tracks subagents via `claudeMetadata.activeSubagents`.
    ///
    /// Note: `claudeMetadata.agentID` is NOT a reliable signal here because
    /// SubagentStart hooks set `agent_id` on the *parent* session's metadata.
    var isSubagentSession: Bool {
        if let path = claudeMetadata?.transcriptPath, path.contains("/subagents/") {
            return true
        }
        return false
    }

    var islandActivityDate: Date {
        updatedAt
    }

    var spotlightPrimaryText: String {
        if let request = permissionRequest {
            return request.summary
        }

        if let prompt = questionPrompt {
            return prompt.title
        }

        if let assistantMessage = lastAssistantMessageText?.trimmedForSurface,
           !assistantMessage.isEmpty {
            return assistantMessage
        }

        return summary
    }

    var spotlightSecondaryText: String? {
        if let request = permissionRequest {
            return request.affectedPath.isEmpty ? nil : request.affectedPath
        }

        if let currentTool = displayCurrentToolName {
            return phase == .completed
                ? summary
                : "Running \(currentTool)"
        }

        let normalizedPrimary = spotlightPrimaryText.trimmedForSurface
        let normalizedSummary = summary.trimmedForSurface
        guard normalizedSummary != normalizedPrimary else {
            return nil
        }

        return summary
    }

    var spotlightCurrentToolLabel: String? {
        displayCurrentToolName
    }

    var spotlightTrackingLabel: String? {
        guard let transcriptPath = trackingTranscriptPath?.trimmedForSurface,
              !transcriptPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: transcriptPath).lastPathComponent
    }

    var spotlightStatusLabel: String {
        switch phase {
        case .running:
            if let currentTool = spotlightCurrentToolLabel {
                return "Live · \(currentTool)"
            }
            return "Live"
        case .waitingForApproval:
            return "Approval"
        case .waitingForAnswer:
            return "Question"
        case .completed:
            return jumpTarget != nil ? "Idle" : "Completed"
        }
    }

    var spotlightTerminalLabel: String? {
        guard let jumpTarget else {
            return nil
        }

        return "\(jumpTarget.terminalApp) · \(jumpTarget.workspaceName)"
    }

    /// Hidden when the terminal is unknown: "Unknown" is the sentinel for
    /// "could not classify the host" and tells the user nothing.
    var spotlightTerminalBadge: String? {
        guard let terminalApp = jumpTarget?.terminalApp.trimmedForSurface,
              !terminalApp.isEmpty,
              terminalApp.lowercased() != "unknown" else {
            return nil
        }
        return terminalApp
    }

    /// Row badge next to the brand icon: the model the session runs on,
    /// falling back to the agent's short name.
    var spotlightAgentBadgeTitle: String {
        SessionModelLabel.display(for: currentModelIdentifier) ?? spotlightAgentShortName
    }

    /// Hover text for the row badge: the agent, the full model id and the terminal.
    var spotlightAgentBadgeHelp: String {
        // Ids the badge can't label (`<synthetic>`) would only add noise.
        let model = SessionModelLabel.display(for: currentModelIdentifier) == nil ? nil : currentModelIdentifier
        return [tool.displayName, model, spotlightTerminalBadge]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var spotlightAgentShortName: String {
        switch tool {
        case .claudeCode:
            "claude"
        case .geminiCLI:
            "gemini"
        case .qwenCode:
            "qwen"
        case .kimiCLI:
            "kimi"
        default:
            tool.shortName.lowercased()
        }
    }

    var spotlightWorkspaceName: String {
        if let workspaceName = jumpTarget?.workspaceName.trimmedForSurface,
           !workspaceName.isEmpty {
            // Cover already-persisted titles that still contain `\xHH` dumps.
            return HexEscapedUTF8.decodeIfNeeded(workspaceName)
        }

        let trimmedTitle = title.trimmedForSurface
        let pieces = trimmedTitle.split(separator: "·", maxSplits: 1).map {
            String($0).trimmedForSurface
        }
        if pieces.count == 2, !pieces[1].isEmpty {
            return HexEscapedUTF8.decodeIfNeeded(pieces[1])
        }

        return HexEscapedUTF8.decodeIfNeeded(trimmedTitle)
    }

    var spotlightWorktreeBranch: String? {
        // This is a SwiftUI computed property read on every layout
        // pass. It MUST stay free of filesystem IO. Calling
        // `WorkspaceNameResolver.gitBranch` here previously walked
        // parent directories every layout, which combined with
        // SwiftUI's measure/layout convergence cycle pinned the
        // process at 99 % CPU during session-list rendering even
        // with the resolver result cached.
        //
        // Read order: hook-supplied metadata wins (already resolved
        // by `BridgeServer` from the hook payload), then the pure
        // string-based worktree-path detector (no IO). Other
        // sessions surface the workspace name without a branch
        // suffix; for branch info on arbitrary `cwd` values to
        // come back, it has to be resolved when the session is
        // created or updated, not from the view body.
        if let branch = claudeMetadata?.worktreeBranch?.trimmedForSurface,
           !branch.isEmpty {
            return branch
        }

        guard let workingDirectory = jumpTarget?.workingDirectory?.trimmedForSurface,
              !workingDirectory.isEmpty else {
            return nil
        }

        return WorkspaceNameResolver.worktreeBranch(for: workingDirectory)
    }

    var spotlightSubagentLabel: String? {
        guard let subagents = claudeMetadata?.activeSubagents, !subagents.isEmpty else {
            return nil
        }
        return "Subagents (\(subagents.count))"
    }

    var spotlightHeadlineText: String {
        let workspaceName = spotlightWorkspaceName
        var headline = workspaceName

        if let branch = spotlightWorktreeBranch {
            headline += " (\(branch))"
        }

        guard let prompt = spotlightHeadlinePromptText else {
            return headline
        }

        guard workspaceName != "/" else {
            return prompt
        }

        return "\(headline) · \(prompt)"
    }

    var spotlightHeadlinePromptText: String? {
        // Headline shows the session topic: the title the agent recorded, else
        // the initial prompt. The latest prompt has its own "You:" line.
        if let title = conversationTitle?.trimmedForSurface, !title.isEmpty {
            return title
        }
        return initialPromptText ?? latestPromptText
    }

    /// List-row line 1: the topic alone, else where the session runs.
    var spotlightRowTopicText: String {
        if let topic = spotlightHeadlinePromptText {
            return topic
        }
        let location = spotlightWorkspaceLabel
        return location.isEmpty ? tool.displayName : location
    }

    /// The workspace a list row shows, or nil when it is `/` or already the topic.
    var spotlightRowWorkspaceText: String? {
        let location = spotlightWorkspaceLabel
        guard !location.isEmpty,
              spotlightWorkspaceName != "/",
              location != spotlightRowTopicText else {
            return nil
        }
        return location
    }

    /// List-row line 2: "workspace · You: latest prompt". The prompt is left
    /// out when excluded or when it repeats the topic.
    func spotlightRowContextLine(_ localizer: SessionTextLocalizer, includesPrompt: Bool) -> String? {
        var parts: [String] = []
        if let workspace = spotlightRowWorkspaceText {
            parts.append(workspace)
        }
        if includesPrompt,
           let prompt = spotlightPromptText,
           prompt != spotlightRowTopicText {
            parts.append(localizer.promptLine(prompt))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "workspace (branch)", the label `spotlightHeadlineText` leads with.
    private var spotlightWorkspaceLabel: String {
        let workspaceName = spotlightWorkspaceName
        guard !workspaceName.isEmpty, let branch = spotlightWorktreeBranch else {
            return workspaceName
        }
        return "\(workspaceName) (\(branch))"
    }

    var spotlightPromptText: String? {
        latestPromptText
    }

    var spotlightPromptLineText: String? {
        localizedPromptLineText(.english)
    }

    func localizedPromptLineText(_ localizer: SessionTextLocalizer) -> String? {
        guard spotlightShowsDetailLines,
              let prompt = spotlightPromptText else {
            return nil
        }

        return localizer.promptLine(prompt)
    }

    var completionReplyRecipientName: String {
        switch tool {
        case .claudeCode:
            return "Claude"
        case .codex:
            return "Codex"
        case .geminiCLI:
            return "Gemini"
        case .openCode:
            return "OpenCode"
        case .qoder:
            return "Qoder"
        case .qwenCode:
            return "Qwen Code"
        case .factory:
            return "Factory"
        case .codebuddy:
            return "CodeBuddy"
        case .cursor:
            return "Cursor"
        case .kimiCLI:
            return "Kimi"
        case .grokBuild:
            return "Grok"
        case .pi:
            return "Pi"
        case .ohMyPi:
            return "Oh My Pi"
        }
    }

    var notificationHeaderPromptLineText: String? {
        localizedNotificationHeaderPromptLineText(.english)
    }

    func localizedNotificationHeaderPromptLineText(_ localizer: SessionTextLocalizer) -> String? {
        guard phase != .completed else {
            return nil
        }

        return localizedPromptLineText(localizer)
    }

    var spotlightActivityLineText: String? {
        localizedActivityLineText(.english)
    }

    /// Status words and Open Island's own summaries go through `localizer`;
    /// assistant messages and tool previews stay verbatim.
    func localizedActivityLineText(_ localizer: SessionTextLocalizer) -> String? {
        guard spotlightShowsDetailLines else {
            return nil
        }

        if let request = permissionRequest?.summary.trimmedForSurface,
           !request.isEmpty {
            return localizer.summary(request)
        }

        if let prompt = questionPrompt?.title.trimmedForSurface,
           !prompt.isEmpty {
            return localizer.summary(prompt)
        }

        switch phase {
        case .running:
            if let activity = spotlightRunningActivityText {
                return activity
            }
            return localizer.word(spotlightPromptLineText == nil ? .running : .thinking)
        case .waitingForApproval:
            return permissionRequest.map { localizer.summary($0.summary.trimmedForSurface) }
                ?? localizer.word(.approvalNeeded)
        case .waitingForAnswer:
            return questionPrompt.map { localizer.summary($0.title.trimmedForSurface) }
                ?? localizer.word(.answerNeeded)
        case .completed:
            if let assistantMessage = lastAssistantMessageText?.trimmedForSurface,
               !assistantMessage.isEmpty {
                return assistantMessage
            }

            return localizer.word(jumpTarget != nil ? .ready : .completed)
        }
    }

    var spotlightActivityTone: SpotlightActivityTone {
        if phase.requiresAttention {
            return .attention
        }

        switch phase {
        case .running:
            return .live
        case .completed:
            if lastAssistantMessageText?.trimmedForSurface.isEmpty == false {
                return .idle
            }
            return .ready
        case .waitingForApproval, .waitingForAnswer:
            return .attention
        }
    }

    var spotlightShowsDetailLines: Bool {
        spotlightShowsDetailLines(at: .now)
    }

    func spotlightShowsDetailLines(at referenceDate: Date) -> Bool {
        if phase == .running || phase.requiresAttention {
            return true
        }

        if referenceDate.timeIntervalSince(islandActivityDate) >= Self.collapsedDetailAgeThreshold {
            return false
        }

        return spotlightPromptText != nil || lastAssistantMessageText?.trimmedForSurface.isEmpty == false
    }

    var spotlightAgeBadge: String {
        let age = max(0, Int(Date.now.timeIntervalSince(islandActivityDate)))

        if age < 60 {
            return "<1m"
        }

        if age < 3_600 {
            return "\(max(1, age / 60))m"
        }

        if age < 86_400 {
            return "\(max(1, age / 3_600))h"
        }

        return "\(max(1, age / 86_400))d"
    }

    func islandPresence(at referenceDate: Date) -> IslandSessionPresence {
        if phase == .running {
            return .running
        }

        if phase.requiresAttention {
            return .active
        }

        if referenceDate.timeIntervalSince(islandActivityDate) <= Self.islandActivityThreshold {
            return .active
        }

        return .inactive
    }

    /// v8 UI-only staleness: keep `SessionPhase.completed` unchanged, but
    /// visually fold older completed rows into the low-priority presentation.
    func isStaleCompletedForIsland(
        at referenceDate: Date,
        threshold: TimeInterval = Self.staleCompletedDisplayThreshold
    ) -> Bool {
        phase == .completed
            && referenceDate.timeIntervalSince(islandActivityDate) >= threshold
    }

    private var spotlightRunningActivityText: String? {
        guard let currentTool = currentToolName?.trimmedForSurface,
              !currentTool.isEmpty else {
            return nil
        }

        let label = Self.currentToolDisplayName(for: currentTool)
        guard let preview = currentCommandPreviewText?.trimmedForSurface,
              !preview.isEmpty else {
            return label
        }

        return "\(label) \(preview)"
    }

    var displayCurrentToolName: String? {
        guard let currentTool = currentToolName?.trimmedForSurface,
              !currentTool.isEmpty else {
            return nil
        }

        return Self.currentToolDisplayName(for: currentTool)
    }

    static func currentToolDisplayName(for toolName: String) -> String {
        switch toolName {
        case "exec_command":
            return "Bash"
        case "Bash":
            return "Bash"
        case "AskUserQuestion":
            return "Question"
        case "ExitPlanMode":
            return "Plan"
        case "apply_patch":
            return "Patch"
        case "write_stdin":
            return "Input"
        case "web_search", "tool_search":
            return "Search"
        case "image_generation", "view_image":
            return "Image"
        case "context_compaction":
            return "Compact"
        case "update_plan":
            return "Plan"
        case "request_user_input":
            return "Question"
        case "spawn_agent":
            return "Subagent"
        default:
            return humanizedToolName(toolName)
        }
    }

    private static func humanizedToolName(_ toolName: String) -> String {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrivatePrefix = String(trimmed.drop(while: { $0 == "_" }))
        let pieces = withoutPrivatePrefix
            .split(separator: "_", omittingEmptySubsequences: true)
            .map { piece -> String in
                let upper = piece.uppercased()
                if ["API", "CI", "ID", "PR", "URL"].contains(upper) {
                    return upper
                }
                return piece.prefix(1).uppercased() + piece.dropFirst().lowercased()
            }
        let label = pieces.joined(separator: " ")
        return label.isEmpty ? toolName : label
    }

    private var initialPromptText: String? {
        let prompt = initialUserPromptText?.trimmedForSurface
        guard let prompt, !prompt.isEmpty else {
            return nil
        }

        return prompt
    }

    private var latestPromptText: String? {
        let prompt = latestUserPromptText?.trimmedForSurface
        guard let prompt, !prompt.isEmpty else {
            return nil
        }

        return prompt
    }

    private var prefersLivePromptHeadline: Bool {
        isProcessAlive || phase == .running || phase.requiresAttention
    }
}

private extension String {
    var trimmedForSurface: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
