import Foundation

/// The Antigravity accounts the island counts as "AGY Pro".
///
/// KEEPER records nothing that tells an Antigravity Pro account apart — its
/// `plan_type` is empty for every Antigravity identity and its rows carry no
/// tier — so the Pro account has to be named. The list lives in
/// `UserDefaults` and is editable in Settings; until someone fills it in, the
/// built-in account in `KeeperUsageReader.defaultAgyProAccounts` is used.
public enum AgyProAccounts {
    /// `UserDefaults` key holding the account list as one free-form string.
    public static let defaultsKey = "usage.agyProAccounts"

    /// Separators people actually type: commas (ASCII and full width),
    /// semicolons, and any whitespace including newlines.
    private static let separators = CharacterSet(charactersIn: ",，;；")
        .union(.whitespacesAndNewlines)

    /// Splits a free-form list into account names.
    ///
    /// The `@domain` suffix is dropped because KEEPER matches the account name
    /// without it, and duplicates are removed case-insensitively while keeping
    /// the first spelling. An address and a bare name for the same account
    /// therefore collapse into one entry.
    public static func parse(_ raw: String) -> [String] {
        var parsed: [String] = []
        var seen = Set<String>()
        for token in raw.components(separatedBy: separators) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let name = trimmed.contains("@")
                ? String(trimmed.split(separator: "@", maxSplits: 1).first ?? "")
                : trimmed
            guard !name.isEmpty else { continue }
            guard seen.insert(name.lowercased()).inserted else { continue }
            parsed.append(name)
        }
        return parsed
    }

    /// The accounts to match against KEEPER rows, falling back to the built-in
    /// account when nothing is configured.
    public static func effective(
        _ raw: String,
        fallback: Set<String> = KeeperUsageReader.defaultAgyProAccounts
    ) -> Set<String> {
        let parsed = parse(raw)
        return parsed.isEmpty ? fallback : Set(parsed)
    }
}
