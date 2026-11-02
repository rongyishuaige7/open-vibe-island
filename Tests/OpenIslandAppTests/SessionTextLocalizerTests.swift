import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

struct SessionTextLocalizerTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func strings(_ language: String) -> [String: String] {
        let path = repoRoot
            .appendingPathComponent("Sources/OpenIslandApp/Resources/\(language).lproj/Localizable.strings")
            .path
        return (NSDictionary(contentsOfFile: path) as? [String: String]) ?? [:]
    }

    private static func localizer(_ language: String) -> SessionTextLocalizer {
        let table = strings(language)
        return SessionTextLocalizer { table[$0] }
    }

    private static func placeholderCount(_ text: String) -> Int {
        let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?@"#)
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    @Test
    func englishKeepsOriginalWording() {
        let english = SessionTextLocalizer.english
        #expect(english.word(.ready) == "Ready")
        #expect(english.promptLine("Fix it") == "You: Fix it")
        #expect(english.summary("Started Codex session in yiapi.") == "Started Codex session in yiapi.")
    }

    @Test
    func simplifiedChineseTranslatesStatusAndSummaries() {
        let zh = Self.localizer("zh-Hans")
        #expect(zh.word(.ready) == "就绪")
        #expect(zh.word(.thinking) == "思考中")
        #expect(zh.promptLine("修一下") == "你：修一下")
        #expect(zh.summary("Started Codex session in yiapi.") == "已在 yiapi 启动 Codex 会话。")
        #expect(zh.summary("Claude Code session ended.") == "Claude Code 会话已结束。")
        #expect(zh.summary("Claude session detected from Ghostty.") == "从 Ghostty 检测到 Claude 会话。")
        #expect(zh.summary("Idle.") == "空闲。")
        #expect(zh.summary("Running Bash.") == "正在运行 Bash。")
        #expect(zh.summary("Prompt: 部署一下") == "提示：部署一下")
        #expect(zh.summary("Codex is working…") == "Codex 正在工作…")
    }

    @Test
    func agentAndUserTextPassesThroughUnchanged() {
        let zh = Self.localizer("zh-Hans")
        for text in ["已完成重构。", "Refactored the parser.", "Started the build", "Prompt:", ""] {
            #expect(zh.summary(text) == text)
        }
    }

    @Test
    func missingTranslationFallsBackToEnglish() {
        let partial = SessionTextLocalizer { $0 == "session.status.ready" ? "就绪" : nil }
        #expect(partial.word(.ready) == "就绪")
        #expect(partial.word(.completed) == "Completed")
        #expect(partial.summary("Idle.") == "Idle.")
    }

    @Test
    func eachTemplateMatchesItsOwnShapeFirst() {
        for template in SessionTextLocalizer.summaryTemplates {
            let sample = template.english.replacingOccurrences(of: "%@", with: "Sample")
            let first = SessionTextLocalizer.summaryTemplates.first {
                SessionTextLocalizer.match(sample, template: $0.english) != nil
            }
            #expect(first?.key == template.key, "\(template.key) is shadowed by \(first?.key ?? "nothing")")
        }
    }

    @Test
    func activityAndPromptLinesUseTheLocalizer() {
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Thinking.",
            updatedAt: Date(timeIntervalSince1970: 10_000),
            codexMetadata: CodexSessionMetadata(lastUserPrompt: "Align the Codex statuses.")
        )
        let zh = Self.localizer("zh-Hans")

        #expect(session.localizedActivityLineText(zh) == "思考中")
        #expect(session.localizedPromptLineText(zh) == "你：Align the Codex statuses.")
        #expect(session.spotlightActivityLineText == "Thinking")
        #expect(session.spotlightPromptLineText == "You: Align the Codex statuses.")
    }

    @Test
    func everyLocaleHasEveryKeyWithMatchingPlaceholders() {
        var expected: [String: String] = [SessionTextLocalizer.promptLineKey: "You: %@"]
        for word in SessionTextLocalizer.Word.allCases {
            expected[word.key] = word.english
        }
        for template in SessionTextLocalizer.summaryTemplates {
            expected[template.key] = template.english
        }
        #expect(expected.count == SessionTextLocalizer.Word.allCases.count + 1 + SessionTextLocalizer.summaryTemplates.count,
                "duplicate key")

        for language in ["en", "zh-Hans", "zh-Hant"] {
            let table = Self.strings(language)
            #expect(!table.isEmpty, "\(language) strings failed to load")
            for (key, english) in expected {
                guard let value = table[key] else {
                    Issue.record("\(language) is missing \(key)")
                    continue
                }
                #expect(Self.placeholderCount(value) == Self.placeholderCount(english), "\(language) \(key)")
                if language == "en" {
                    #expect(value == english, "en.lproj drifted from code for \(key)")
                }
            }
        }
    }
}
