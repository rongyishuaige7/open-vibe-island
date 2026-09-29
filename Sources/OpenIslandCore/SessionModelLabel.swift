import Foundation

/// Turns raw model identifiers reported by agents into short row badges.
///
/// Claude ids (`claude-opus-5-5`, `claude-3-5-sonnet-20241022`) become
/// `Opus 5.5` / `Sonnet 3.5`. Other providers already use readable ids
/// (`gpt-5.6-sol`, `gemini-2.5-pro`), so they only lose provider prefixes
/// and get clipped to the badge width.
public enum SessionModelLabel {
    static let maximumLength = 18

    private static let claudeFamilies: Set<String> = ["opus", "sonnet", "haiku"]

    public static func display(for rawModel: String?) -> String? {
        guard var model = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              // Claude transcripts write `<synthetic>` for locally generated replies.
              !model.hasPrefix("<") else {
            return nil
        }

        // `provider/model` (Pi, OpenRouter) → `model`.
        if let slash = model.lastIndex(of: "/") {
            model = String(model[model.index(after: slash)...])
        }
        // Context-window suffix such as `[1m]`.
        if let bracket = model.firstIndex(of: "[") {
            model = String(model[..<bracket])
        }
        model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return nil
        }

        return claudeLabel(for: model) ?? clipped(model)
    }

    private static func claudeLabel(for model: String) -> String? {
        var lowered = model.lowercased()
        // Bedrock / Vertex style ids: `anthropic.claude-…-v1:0`, `claude-…@20250101`.
        if lowered.hasPrefix("anthropic.") {
            lowered.removeFirst("anthropic.".count)
        }
        for separator in ["@", ":"] {
            if let index = lowered.firstIndex(of: Character(separator)) {
                lowered = String(lowered[..<index])
            }
        }
        guard lowered.hasPrefix("claude-") else {
            return nil
        }

        let tokens = lowered.dropFirst("claude-".count).split(separator: "-").map(String.init)
        guard let family = tokens.first(where: claudeFamilies.contains) else {
            return nil
        }

        // Version parts are short numbers; dates (`20241022`) and `v1` markers are dropped.
        let version = tokens
            .filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
            .joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    private static func clipped(_ value: String) -> String {
        guard value.count > maximumLength else {
            return value
        }
        return String(value.prefix(maximumLength - 1)) + "…"
    }
}

extension AgentSession {
    /// The raw model id the session last reported, whichever agent it belongs to.
    public var currentModelIdentifier: String? {
        let candidates = [
            claudeMetadata?.model,
            codexMetadata?.model,
            openCodeMetadata?.model,
            cursorMetadata?.model,
            piMetadata?.model,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
