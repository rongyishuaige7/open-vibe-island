import Foundation

/// Whether the opt-in PI Desktop plugin is present and enabled.
public struct PiDesktopIntegrationStatus: Equatable, Sendable {
    /// `/Applications/PI-Desktop.app` exists.
    public var appInstalled: Bool
    /// `~/.pi-desktop` exists, i.e. the app has run at least once.
    public var piDesktopHomeExists: Bool
    /// The plugin directory with a manifest and entry point exists.
    public var pluginInstalled: Bool
    /// PI Desktop's registry lists the plugin with `enabled: true`.
    public var pluginEnabled: Bool
    public var pluginPath: URL?
    public var registryURL: URL?

    public init(
        appInstalled: Bool = false,
        piDesktopHomeExists: Bool = false,
        pluginInstalled: Bool = false,
        pluginEnabled: Bool = false,
        pluginPath: URL? = nil,
        registryURL: URL? = nil
    ) {
        self.appInstalled = appInstalled
        self.piDesktopHomeExists = piDesktopHomeExists
        self.pluginInstalled = pluginInstalled
        self.pluginEnabled = pluginEnabled
        self.pluginPath = pluginPath
        self.registryURL = registryURL
    }

    /// Session-level focus needs both halves; anything less falls back to
    /// plain app activation.
    public var supportsSessionFocus: Bool {
        pluginInstalled && pluginEnabled
    }

    public var isInstalled: Bool {
        pluginInstalled
    }
}

public enum PiDesktopIntegrationError: Error, Equatable, LocalizedError {
    case unsafeRegistry(String)

    public var errorDescription: String? {
        switch self {
        case let .unsafeRegistry(detail):
            "PI Desktop's plugin registry was left unchanged: \(detail)"
        }
    }
}

/// Installs the opt-in PI Desktop plugin that powers session-level focus.
///
/// The plugin is deliberately tiny: its only job is to serve one Unix socket
/// and answer `focus` by calling `desktop.invoke("session/open", [id])`. It
/// declares `desktop.control` (high risk) and nothing else, because reading
/// sessions stays with Open Island's SQLite poller.
public final class PiDesktopIntegrationManager: @unchecked Sendable {
    public static let pluginID = "local.openisland.pi-desktop-bridge"
    public static let pluginDirectoryName = pluginID
    public static let pluginFileName = "main.js"
    public static let manifestFileName = "manifest.json"
    public static let pluginVersion = "0.1.0"
    public static let appBundlePath = "/Applications/PI-Desktop.app"

    private let piDesktopHome: URL
    private let fileManager: FileManager

    public init(
        piDesktopHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi-desktop", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.piDesktopHome = piDesktopHome
        self.fileManager = fileManager
    }

    public var pluginsRoot: URL {
        piDesktopHome.appendingPathComponent("plugins", isDirectory: true)
    }

    public var pluginDirectory: URL {
        pluginsRoot
            .appendingPathComponent("dev", isDirectory: true)
            .appendingPathComponent(Self.pluginDirectoryName, isDirectory: true)
    }

    public var registryURL: URL {
        pluginsRoot.appendingPathComponent("registry.json")
    }

    public func status() -> PiDesktopIntegrationStatus {
        let entryURL = pluginDirectory.appendingPathComponent(Self.pluginFileName)
        let manifestURL = pluginDirectory.appendingPathComponent(Self.manifestFileName)
        let installed = fileManager.fileExists(atPath: entryURL.path)
            && fileManager.fileExists(atPath: manifestURL.path)
        let enabled = installed && registryListsPlugin()

        return PiDesktopIntegrationStatus(
            appInstalled: fileManager.fileExists(atPath: Self.appBundlePath),
            piDesktopHomeExists: fileManager.fileExists(atPath: piDesktopHome.path),
            pluginInstalled: installed,
            pluginEnabled: enabled,
            pluginPath: installed ? pluginDirectory : nil,
            registryURL: registryURL
        )
    }

    @discardableResult
    public func install(pluginSourceData: Data) throws -> PiDesktopIntegrationStatus {
        try fileManager.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try manifestData().write(to: pluginDirectory.appendingPathComponent(Self.manifestFileName))
        try pluginSourceData.write(to: pluginDirectory.appendingPathComponent(Self.pluginFileName))
        return status()
    }

    @discardableResult
    public func uninstall() throws -> PiDesktopIntegrationStatus {
        if fileManager.fileExists(atPath: pluginDirectory.path) {
            try fileManager.removeItem(at: pluginDirectory)
        }
        pruneRegistryEntry()
        return status()
    }

    /// Removes only our own entry so a leftover reference does not show up as a
    /// broken plugin in PI Desktop. A registry that cannot be parsed is left
    /// untouched — deleting a user's plugin list would be far worse than a
    /// stale row.
    private func pruneRegistryEntry() {
        guard let data = try? Data(contentsOf: registryURL),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        let remaining = entries.filter { ($0["id"] as? String) != Self.pluginID }
        guard remaining.count != entries.count,
              let serialized = try? JSONSerialization.data(
                withJSONObject: remaining,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return
        }
        try? serialized.write(to: registryURL, options: .atomic)
    }

    private func registryListsPlugin() -> Bool {
        guard let data = try? Data(contentsOf: registryURL),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        return entries.contains { entry in
            (entry["id"] as? String) == Self.pluginID && (entry["enabled"] as? Bool) == true
        }
    }

    private func manifestData() throws -> Data {
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "id": Self.pluginID,
            "name": "Open Island Bridge",
            "version": Self.pluginVersion,
            "description": "Lets Open Island focus a PI Desktop conversation. Read-only bridge; no session content leaves the machine.",
            "main": Self.pluginFileName,
            "permissions": ["desktop.control"],
            "engines": ["piDesktop": ">=0.21.0"],
            "activationEvents": ["onStartup"]
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }
}
