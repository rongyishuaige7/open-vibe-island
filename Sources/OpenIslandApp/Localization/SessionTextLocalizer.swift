import Foundation

/// Localizes the English text Open Island itself puts on session rows:
/// status words, the "You:" prompt prefix, and the summaries hooks and
/// rollout parsing store as plain English. Agent- and user-authored text
/// matches no template and passes through unchanged.
struct SessionTextLocalizer: Sendable {
    /// Localized format for a key, or nil to use the English fallback.
    let lookup: @Sendable (String) -> String?

    /// Open Island's original English wording, whatever the app language.
    static let english = SessionTextLocalizer { _ in nil }

    /// The app's current language.
    static func current(_ language: LanguageManager = .shared) -> SessionTextLocalizer {
        SessionTextLocalizer { key in
            let value = language.t(key)
            return value == key ? nil : value
        }
    }

    // MARK: - Status words

    enum Word: String, CaseIterable, Sendable {
        case running, thinking, approvalNeeded, answerNeeded, ready, completed

        var key: String { "session.status.\(rawValue)" }

        var english: String {
            switch self {
            case .running: "Running"
            case .thinking: "Thinking"
            case .approvalNeeded: "Approval needed"
            case .answerNeeded: "Answer needed"
            case .ready: "Ready"
            case .completed: "Completed"
            }
        }
    }

    func word(_ word: Word) -> String {
        lookup(word.key) ?? word.english
    }

    // MARK: - Prompt line

    static let promptLineKey = "session.promptLine"

    /// "You: <prompt>" with the prompt kept verbatim.
    func promptLine(_ prompt: String) -> String {
        guard let format = lookup(Self.promptLineKey) else {
            return "You: \(prompt)"
        }
        return String(format: format, prompt)
    }

    // MARK: - Summaries

    struct SummaryTemplate: Sendable {
        let key: String
        /// The exact English Open Island writes, with `%@` for each value.
        let english: String
    }

    /// Where two templates could match the same text, the more specific one
    /// comes first (checked by tests).
    static let summaryTemplates: [SummaryTemplate] = [
        // Session lifecycle (hooks, rollout discovery, bridge).
        .init(key: "session.summary.started", english: "Started %@ session in %@."),
        .init(key: "session.summary.resumed", english: "Resumed %@ session in %@."),
        .init(key: "session.summary.clearedContext", english: "Cleared %@ context in %@."),
        .init(key: "session.summary.compactedContext", english: "Compacted %@ context in %@."),
        .init(key: "session.summary.endedIn", english: "%@ session ended in %@."),
        .init(key: "session.summary.ended", english: "%@ session ended."),
        .init(key: "session.summary.compacting", english: "%@ is compacting the conversation."),
        // Sessions synthesized from a live process.
        .init(key: "session.summary.detectedFrom", english: "%@ session detected from %@."),
        .init(key: "session.summary.detected", english: "%@ session detected."),
        .init(key: "session.summary.agentDetectedFrom", english: "%@ agent detected from %@."),
        .init(key: "session.summary.agentDetected", english: "%@ agent detected."),
        // Codex hooks.
        .init(key: "session.summary.codexPreparingBash", english: "Codex is preparing a Bash command in %@."),
        .init(key: "session.summary.codexWaitingPermissionIn", english: "Codex is waiting for permission approval in %@."),
        .init(key: "session.summary.codexBashResult", english: "Codex reported a Bash result in %@."),
        .init(key: "session.summary.codexNewPrompt", english: "Codex received a new prompt in %@."),
        .init(key: "session.summary.codexTurnCompletedIn", english: "Codex completed a turn in %@."),
        .init(key: "session.summary.codexWantsToUse", english: "Codex wants to use %@."),
        .init(key: "session.summary.codexRequestingPermission", english: "Codex is requesting permission."),
        .init(key: "session.summary.codexWantsShell", english: "Codex wants to run a shell command."),
        // Codex app server and rollout parsing.
        .init(key: "session.summary.codexWaitingApproval", english: "Codex is waiting for approval."),
        .init(key: "session.summary.codexWaitingInput", english: "Codex is waiting for input."),
        .init(key: "session.summary.codexWorking", english: "Codex is working…"),
        .init(key: "session.summary.codexSession", english: "Codex session."),
        .init(key: "session.summary.idle", english: "Idle."),
        .init(key: "session.summary.turnFailed", english: "Turn failed."),
        .init(key: "session.summary.turnStalled", english: "Turn stalled."),
        .init(key: "session.summary.turnInterrupted", english: "Codex turn was interrupted."),
        .init(key: "session.summary.threadClosed", english: "Codex thread closed."),
        .init(key: "session.summary.threadArchived", english: "Codex thread archived."),
        .init(key: "session.summary.rateLimited", english: "Rate limit reached."),
        .init(key: "session.summary.runningTool", english: "Running %@."),
        .init(key: "session.summary.thinking", english: "Thinking."),
        .init(key: "session.summary.prompt", english: "Prompt: %@"),
        // Bridge and Claude hooks.
        .init(key: "session.summary.permissionInactive", english: "Permission request is no longer active."),
        .init(key: "session.summary.approvalHandledElsewhere", english: "Approval was handled outside Open Island."),
        .init(key: "session.summary.hookDisconnected", english: "Hook process disconnected."),
        .init(key: "session.summary.claudeExitPlan", english: "Claude wants to exit plan mode and start implementation."),
    ]

    /// Localized summary when `text` is one of Open Island's own English
    /// templates; any other text is returned unchanged.
    func summary(_ text: String) -> String {
        for template in Self.summaryTemplates {
            guard let values = Self.match(text, template: template.english) else {
                continue
            }
            guard let format = lookup(template.key) else {
                return text
            }
            return String(format: format, arguments: values.map { $0 as CVarArg })
        }
        return text
    }

    /// Values captured by the template's `%@` placeholders, or nil when the
    /// text does not have the template's shape.
    static func match(_ text: String, template: String) -> [String]? {
        let literals = template.components(separatedBy: "%@")
        guard literals.count > 1 else {
            return text == template ? [] : nil
        }
        guard text.hasPrefix(literals[0]) else {
            return nil
        }

        var rest = text.dropFirst(literals[0].count)
        var values: [String] = []
        for literal in literals.dropFirst().dropLast() {
            guard let range = rest.range(of: literal), range.lowerBound > rest.startIndex else {
                return nil
            }
            values.append(String(rest[..<range.lowerBound]))
            rest = rest[range.upperBound...]
        }

        let last = literals[literals.count - 1]
        guard rest.hasSuffix(last), rest.count > last.count else {
            return nil
        }
        values.append(String(rest.dropLast(last.count)))
        return values
    }
}
