import Foundation

public struct DSHProfileIntegrationStatus: Equatable, Sendable {
    public var profileName: String
    public var profileURL: URL
    public var pluginFileURL: URL
    public var patchFileURL: URL
    public var isInstalled: Bool
    public var patchExists: Bool

    public init(
        profileName: String,
        profileURL: URL,
        pluginFileURL: URL,
        patchFileURL: URL,
        isInstalled: Bool,
        patchExists: Bool
    ) {
        self.profileName = profileName
        self.profileURL = profileURL
        self.pluginFileURL = pluginFileURL
        self.patchFileURL = patchFileURL
        self.isInstalled = isInstalled
        self.patchExists = patchExists
    }
}

public struct DSHIntegrationStatus: Equatable, Sendable {
    public var dshHomeExists: Bool
    public var profiles: [DSHProfileIntegrationStatus]

    public var isInstalled: Bool {
        profiles.contains(where: \.isInstalled)
    }

    public var installedProfileNames: [String] {
        profiles.filter(\.isInstalled).map(\.profileName)
    }

    public init(dshHomeExists: Bool = false, profiles: [DSHProfileIntegrationStatus] = []) {
        self.dshHomeExists = dshHomeExists
        self.profiles = profiles
    }
}

public enum DSHIntegrationError: Error, LocalizedError, Equatable {
    case dshNotFound
    case noWritableProfile
    case unsafePatch(String)

    public var errorDescription: String? {
        switch self {
        case .dshNotFound:
            "DeepSeek Harness was not found in ~/.dsh."
        case .noWritableProfile:
            "No DeepSeek Harness profile could be updated."
        case let .unsafePatch(profile):
            "The \(profile) profile's cordis.patch.yml is not a patch list; refusing to edit it."
        }
    }
}

/// Installs a self-contained Host plugin beside a DSH profile and registers it
/// in the profile's user-owned `cordis.patch.yml`. The Electron-managed
/// `package.json` and pnpm lockfile are deliberately never touched.
public struct DSHIntegrationManager {
    public static let pluginFileName = "open-island-dsh.mjs"
    public static let markerStart = "# >>> Open Island DSH bridge (managed) >>>"
    public static let markerEnd = "# <<< Open Island DSH bridge (managed) <<<"

    private static let managedBlock = """
    \(markerStart)
    - insert:
        - id: open-island-dsh-bridge
          name: './\(pluginFileName)'
    \(markerEnd)
    """

    private let dshHome: URL
    private let fileManager: FileManager

    public init(
        dshHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.dshHome = dshHome
        self.fileManager = fileManager
    }

    public var profilesRoot: URL {
        dshHome.appendingPathComponent("profiles", isDirectory: true)
    }

    public func status() -> DSHIntegrationStatus {
        let dshHomeExists = fileManager.fileExists(atPath: dshHome.path)
        let profiles = availableProfileNames().map { name -> DSHProfileIntegrationStatus in
            let profileURL = profilesRoot.appendingPathComponent(name, isDirectory: true)
            let pluginURL = profileURL.appendingPathComponent(Self.pluginFileName)
            let patchURL = profileURL.appendingPathComponent("cordis.patch.yml")
            let patch = (try? String(contentsOf: patchURL, encoding: .utf8)) ?? ""
            return DSHProfileIntegrationStatus(
                profileName: name,
                profileURL: profileURL,
                pluginFileURL: pluginURL,
                patchFileURL: patchURL,
                isInstalled: fileManager.fileExists(atPath: pluginURL.path)
                    && patch.contains(Self.markerStart)
                    && patch.contains(Self.markerEnd),
                patchExists: fileManager.fileExists(atPath: patchURL.path)
            )
        }
        return DSHIntegrationStatus(dshHomeExists: dshHomeExists, profiles: profiles)
    }

    @discardableResult
    public func install(pluginSourceData: Data) throws -> DSHIntegrationStatus {
        let profiles = availableProfileNames()
        guard !profiles.isEmpty else {
            throw self.dshHomeExists ? DSHIntegrationError.noWritableProfile : DSHIntegrationError.dshNotFound
        }

        var installedAny = false
        for name in profiles {
            let profileURL = profilesRoot.appendingPathComponent(name, isDirectory: true)
            let pluginURL = profileURL.appendingPathComponent(Self.pluginFileName)
            let patchURL = profileURL.appendingPathComponent("cordis.patch.yml")

            do {
                try fileManager.createDirectory(at: profileURL, withIntermediateDirectories: true)

                let existing = (try? String(contentsOf: patchURL, encoding: .utf8)) ?? "[]\n"
                guard isPatchList(existing) else {
                    throw DSHIntegrationError.unsafePatch(name)
                }
                if !existing.contains(Self.markerStart) {
                    if fileManager.fileExists(atPath: patchURL.path) {
                        try backup(patchURL: patchURL)
                    }
                    let updated = appendingManagedBlock(to: existing)
                    try updated.write(to: patchURL, atomically: true, encoding: .utf8)
                }
                try pluginSourceData.write(to: pluginURL, options: .atomic)
                installedAny = true
            } catch let error as DSHIntegrationError {
                throw error
            } catch {
                continue
            }
        }

        guard installedAny else {
            throw DSHIntegrationError.noWritableProfile
        }
        return status()
    }

    @discardableResult
    public func uninstall() throws -> DSHIntegrationStatus {
        for name in availableProfileNames() {
            let profileURL = profilesRoot.appendingPathComponent(name, isDirectory: true)
            let pluginURL = profileURL.appendingPathComponent(Self.pluginFileName)
            let patchURL = profileURL.appendingPathComponent("cordis.patch.yml")

            if let existing = try? String(contentsOf: patchURL, encoding: .utf8),
               existing.contains(Self.markerStart) {
                let updated = removingManagedBlock(from: existing)
                if updated != existing {
                    try backup(patchURL: patchURL)
                    try updated.write(to: patchURL, atomically: true, encoding: .utf8)
                }
            }

            if fileManager.fileExists(atPath: pluginURL.path) {
                try? fileManager.removeItem(at: pluginURL)
            }
        }
        return status()
    }

    public var dshHomeExists: Bool {
        fileManager.fileExists(atPath: dshHome.path)
    }

    private func availableProfileNames() -> [String] {
        ["desktop", "web"].filter { name in
            var isDirectory: ObjCBool = false
            let path = profilesRoot.appendingPathComponent(name, isDirectory: true).path
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private func isPatchList(_ contents: String) -> Bool {
        let lines = meaningfulLines(contents)
        return lines.isEmpty || lines == ["[]"] || lines.first?.hasPrefix("-") == true
    }

    private func meaningfulLines(_ contents: String) -> [String] {
        contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func appendingManagedBlock(to contents: String) -> String {
        if meaningfulLines(contents) == ["[]"] {
            let withoutEmptyArray = contents
                .components(separatedBy: .newlines)
                .filter { $0.trimmingCharacters(in: .whitespaces) != "[]" }
                .joined(separator: "\n")
            return appendingManagedBlock(to: withoutEmptyArray)
        }

        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = trimmed.isEmpty ? "" : contents
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        body += Self.managedBlock
        if !body.hasSuffix("\n") { body += "\n" }
        return body
    }

    private func removingManagedBlock(from contents: String) -> String {
        guard let start = contents.range(of: Self.markerStart),
              let end = contents.range(of: Self.markerEnd, range: start.lowerBound..<contents.endIndex) else {
            return contents
        }
        var result = contents
        var removalEnd = end.upperBound
        if removalEnd < result.endIndex, result[removalEnd] == "\n" {
            removalEnd = result.index(after: removalEnd)
        }
        result.removeSubrange(start.lowerBound..<removalEnd)
        // Collapse a leading blank line left by removing the only entry.
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "[]\n"
        }
        return result
    }

    private func backup(patchURL: URL) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let suffix = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupURL = patchURL.appendingPathExtension("openisland-backup-\(suffix)")
        if fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: patchURL, to: backupURL)
    }
}
