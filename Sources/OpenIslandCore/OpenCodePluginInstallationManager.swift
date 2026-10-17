import Foundation

public struct OpenCodePluginInstallationStatus: Equatable, Sendable {
    public var openCodeConfigDirectory: URL
    public var pluginsDirectory: URL
    public var configURL: URL
    public var pluginFileURL: URL
    public var manifestURL: URL
    public var pluginFilePresent: Bool
    public var pluginRegistered: Bool
    public var manifest: OpenCodePluginInstallerManifest?

    public var isInstalled: Bool {
        pluginFilePresent && pluginRegistered
    }

    public init(
        openCodeConfigDirectory: URL,
        pluginsDirectory: URL,
        configURL: URL,
        pluginFileURL: URL,
        manifestURL: URL,
        pluginFilePresent: Bool,
        pluginRegistered: Bool,
        manifest: OpenCodePluginInstallerManifest?
    ) {
        self.openCodeConfigDirectory = openCodeConfigDirectory
        self.pluginsDirectory = pluginsDirectory
        self.configURL = configURL
        self.pluginFileURL = pluginFileURL
        self.manifestURL = manifestURL
        self.pluginFilePresent = pluginFilePresent
        self.pluginRegistered = pluginRegistered
        self.manifest = manifest
    }
}

public struct OpenCodePluginInstallerManifest: Equatable, Codable, Sendable {
    public static let fileName = "open-island-opencode-plugin-install.json"

    public var pluginPath: String
    public var installedAt: Date

    public init(pluginPath: String, installedAt: Date = .now) {
        self.pluginPath = pluginPath
        self.installedAt = installedAt
    }
}

public enum OpenCodePluginInstallationError: Error, LocalizedError, Equatable {
    /// The existing `config.json` cannot be edited without risking unrelated
    /// user settings.
    case unsafeConfig(String)

    public var errorDescription: String? {
        switch self {
        case let .unsafeConfig(detail):
            "OpenCode config.json was left unchanged because it could not be edited safely: \(detail)"
        }
    }
}

public final class OpenCodePluginInstallationManager: @unchecked Sendable {
    public static let pluginFileName = "open-island.js"

    public let openCodeConfigDirectory: URL
    private let fileManager: FileManager

    public init(
        openCodeConfigDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.openCodeConfigDirectory = openCodeConfigDirectory
        self.fileManager = fileManager
    }

    private var pluginsDirectory: URL {
        openCodeConfigDirectory.appendingPathComponent("plugins", isDirectory: true)
    }

    private var pluginFileURL: URL {
        pluginsDirectory.appendingPathComponent(Self.pluginFileName)
    }

    private var configURL: URL {
        openCodeConfigDirectory.appendingPathComponent("config.json")
    }

    private var manifestURL: URL {
        openCodeConfigDirectory.appendingPathComponent(OpenCodePluginInstallerManifest.fileName)
    }

    public func status() throws -> OpenCodePluginInstallationStatus {
        let pluginPresent = fileManager.fileExists(atPath: pluginFileURL.path)
        let registered = isPluginRegistered()
        let manifest = try loadManifest()

        return OpenCodePluginInstallationStatus(
            openCodeConfigDirectory: openCodeConfigDirectory,
            pluginsDirectory: pluginsDirectory,
            configURL: configURL,
            pluginFileURL: pluginFileURL,
            manifestURL: manifestURL,
            pluginFilePresent: pluginPresent,
            pluginRegistered: registered,
            manifest: manifest
        )
    }

    @discardableResult
    public func install(pluginSourceData: Data) throws -> OpenCodePluginInstallationStatus {
        // Validate the existing config before writing anything. A malformed or
        // unexpectedly shaped config must fail the install instead of being
        // replaced with a fresh object (which would drop user settings and
        // unrelated plugins).
        try validateConfigForInstall()

        try fileManager.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)

        // Write the JS plugin file
        try pluginSourceData.write(to: pluginFileURL, options: .atomic)

        // Register in config.json
        try registerPluginInConfig()

        // Write manifest
        let manifest = OpenCodePluginInstallerManifest(pluginPath: pluginFileURL.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        return try status()
    }

    @discardableResult
    public func uninstall() throws -> OpenCodePluginInstallationStatus {
        // Remove plugin file
        if fileManager.fileExists(atPath: pluginFileURL.path) {
            try fileManager.removeItem(at: pluginFileURL)
        }

        // Remove from config.json
        try unregisterPluginFromConfig()

        // Remove manifest
        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.removeItem(at: manifestURL)
        }

        return try status()
    }

    // MARK: - Config.json manipulation

    private func pluginFileReference() -> String {
        "file://\(pluginFileURL.path)"
    }

    private func isPluginRegistered() -> Bool {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugin"] as? [String] else {
            return false
        }

        let ref = pluginFileReference()
        return plugins.contains { $0 == ref || $0.hasSuffix("/\(Self.pluginFileName)") }
    }

    private func registerPluginInConfig() throws {
        let ref = pluginFileReference()

        var json = try loadConfigObject()
        var plugins = try decodedPlugins(from: json)

        // Remove any existing Open Island plugin references
        plugins.removeAll { $0 == ref || $0.hasSuffix("/\(Self.pluginFileName)") }
        plugins.append(ref)

        json["plugin"] = plugins

        if fileManager.fileExists(atPath: configURL.path) {
            try backupFile(at: configURL)
        }

        let outputData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try outputData.write(to: configURL, options: .atomic)
    }

    /// Rejects configs that a string-only plugin mutation cannot round-trip.
    private func validateConfigForInstall() throws {
        let json = try loadConfigObject()
        _ = try decodedPlugins(from: json)
    }

    private func loadConfigObject() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: configURL)

        // An empty file is equivalent to an absent config.
        if data.isEmpty {
            return [:]
        }
        if let raw = String(data: data, encoding: .utf8),
           raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OpenCodePluginInstallationError.unsafeConfig("config.json is not valid JSON")
        }

        guard let json = object as? [String: Any] else {
            throw OpenCodePluginInstallationError.unsafeConfig("config.json is not a JSON object")
        }

        return json
    }

    private func decodedPlugins(from json: [String: Any]) throws -> [String] {
        guard let rawPlugins = json["plugin"] else {
            return []
        }

        guard let plugins = rawPlugins as? [String] else {
            throw OpenCodePluginInstallationError.unsafeConfig(
                "the \"plugin\" value must be an array of strings"
            )
        }

        return plugins
    }

    private func unregisterPluginFromConfig() throws {
        guard let data = try? Data(contentsOf: configURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var plugins = json["plugin"] as? [String] else {
            return
        }

        let ref = pluginFileReference()
        let before = plugins.count
        plugins.removeAll { $0 == ref || $0.hasSuffix("/\(Self.pluginFileName)") }

        guard plugins.count != before else {
            return
        }

        if fileManager.fileExists(atPath: configURL.path) {
            try backupFile(at: configURL)
        }

        if plugins.isEmpty {
            json.removeValue(forKey: "plugin")
        } else {
            json["plugin"] = plugins
        }

        let outputData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try outputData.write(to: configURL, options: .atomic)
    }

    // MARK: - Helpers

    private func loadManifest() throws -> OpenCodePluginInstallerManifest? {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OpenCodePluginInstallerManifest.self, from: data)
    }

    private func backupFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupURL = url.appendingPathExtension("backup.\(timestamp)")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }
}
