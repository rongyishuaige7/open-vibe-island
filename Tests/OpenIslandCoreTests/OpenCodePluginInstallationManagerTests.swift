import Foundation
import Testing
@testable import OpenIslandCore

struct OpenCodePluginInstallationManagerTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func readJSON(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var pluginSource: Data {
        Data("export default function plugin() {}".utf8)
    }

    @Test
    func invalidJSONIsRejectedWithoutTouchingConfigOrPluginFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config.json")
        let original = #"{"plugin": ["other"],"#
        try write(original, to: configURL)

        let manager = OpenCodePluginInstallationManager(openCodeConfigDirectory: directory)

        #expect(throws: OpenCodePluginInstallationError.self) {
            try manager.install(pluginSourceData: pluginSource)
        }

        #expect(try String(contentsOf: configURL, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("plugins/open-island.js").path
        ))
    }

    @Test
    func nonStringPluginEntriesAreRejectedWithoutRewritingConfig() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config.json")
        let original = #"{"theme":"dark","plugin":[{"name":"other"}]}"#
        try write(original, to: configURL)

        let manager = OpenCodePluginInstallationManager(openCodeConfigDirectory: directory)

        #expect(throws: OpenCodePluginInstallationError.self) {
            try manager.install(pluginSourceData: pluginSource)
        }

        #expect(try String(contentsOf: configURL, encoding: .utf8) == original)
    }

    @Test
    func installPreservesUnrelatedKeysAndPlugins() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config.json")
        try write(#"{"theme":"dark","plugin":["file:///tmp/other.js"]}"#, to: configURL)

        let manager = OpenCodePluginInstallationManager(openCodeConfigDirectory: directory)
        try manager.install(pluginSourceData: pluginSource)

        let json = try readJSON(at: configURL)
        let plugins = try #require(json["plugin"] as? [String])

        #expect(json["theme"] as? String == "dark")
        #expect(plugins.contains("file:///tmp/other.js"))
        #expect(plugins.contains { $0.hasSuffix("/plugins/open-island.js") })
    }

    @Test
    func uninstallRemovesOnlyTheManagedPlugin() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config.json")
        try write(#"{"plugin":["file:///tmp/other.js"]}"#, to: configURL)

        let manager = OpenCodePluginInstallationManager(openCodeConfigDirectory: directory)
        try manager.install(pluginSourceData: pluginSource)
        try manager.uninstall()

        let json = try readJSON(at: configURL)
        let plugins = try #require(json["plugin"] as? [String])

        #expect(plugins == ["file:///tmp/other.js"])
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("plugins/open-island.js").path
        ))
    }

    @Test
    func emptyConfigIsTreatedAsAbsent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config.json")
        try write("  \n", to: configURL)

        let manager = OpenCodePluginInstallationManager(openCodeConfigDirectory: directory)
        try manager.install(pluginSourceData: pluginSource)

        let json = try readJSON(at: configURL)
        let plugins = try #require(json["plugin"] as? [String])
        #expect(plugins.count == 1)
    }

    @Test
    func installCreatesConfigWhenMissing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = OpenCodePluginInstallationManager(openCodeConfigDirectory: directory)
        try manager.install(pluginSourceData: pluginSource)

        let configURL = directory.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configURL.path))
    }
}
