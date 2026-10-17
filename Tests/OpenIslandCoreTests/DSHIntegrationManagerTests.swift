import Foundation
import Testing
@testable import OpenIslandCore

struct DSHIntegrationManagerTests {
    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-dsh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("profiles/desktop", isDirectory: true),
            withIntermediateDirectories: true
        )
        return url
    }

    @Test
    func installAndUninstallPreserveExistingPatchEntries() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profiles/desktop", isDirectory: true)
        let patchURL = profile.appendingPathComponent("cordis.patch.yml")
        let original = """
        # user patch
        - id: ui-theme
          name: "@deepseek-ai/dsh-client-ui-theme"
          config:
            preference: dark
        """
        try original.write(to: patchURL, atomically: true, encoding: .utf8)

        let manager = DSHIntegrationManager(dshHome: home)
        let status = try manager.install(pluginSourceData: Data("export function apply() {}".utf8))

        #expect(status.isInstalled)
        #expect(status.installedProfileNames == ["desktop"])
        #expect(FileManager.default.fileExists(atPath: profile.appendingPathComponent("open-island-dsh.mjs").path))

        let installedPatch = try String(contentsOf: patchURL, encoding: .utf8)
        #expect(installedPatch.contains("ui-theme"))
        #expect(installedPatch.contains(DSHIntegrationManager.markerStart))
        #expect(installedPatch.contains("open-island-dsh.mjs"))

        // Re-installing is idempotent.
        _ = try manager.install(pluginSourceData: Data("export function apply() {}".utf8))
        let reinstalledPatch = try String(contentsOf: patchURL, encoding: .utf8)
        #expect(reinstalledPatch.components(separatedBy: DSHIntegrationManager.markerStart).count == 2)

        let removed = try manager.uninstall()
        #expect(!removed.isInstalled)
        #expect(!FileManager.default.fileExists(atPath: profile.appendingPathComponent("open-island-dsh.mjs").path))
        let uninstalledPatch = try String(contentsOf: patchURL, encoding: .utf8)
        #expect(uninstalledPatch.contains("ui-theme"))
        #expect(!uninstalledPatch.contains(DSHIntegrationManager.markerStart))
    }

    @Test
    func emptyArrayPatchIsReplacedWithAValidPatchList() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profiles/desktop", isDirectory: true)
        let patchURL = profile.appendingPathComponent("cordis.patch.yml")
        try "# comments only\n[]\n".write(to: patchURL, atomically: true, encoding: .utf8)

        let manager = DSHIntegrationManager(dshHome: home)
        _ = try manager.install(pluginSourceData: Data("export function apply() {}".utf8))

        let patch = try String(contentsOf: patchURL, encoding: .utf8)
        #expect(patch.contains("# comments only"))
        #expect(!patch.contains("\n[]"))
        #expect(patch.contains(DSHIntegrationManager.markerStart))
    }

    @Test
    func unsafePatchIsLeftUntouched() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profiles/desktop", isDirectory: true)
        let patchURL = profile.appendingPathComponent("cordis.patch.yml")
        let original = "theme: dark\n"
        try original.write(to: patchURL, atomically: true, encoding: .utf8)

        let manager = DSHIntegrationManager(dshHome: home)
        #expect(throws: DSHIntegrationError.self) {
            try manager.install(pluginSourceData: Data("export function apply() {}".utf8))
        }
        #expect(try String(contentsOf: patchURL, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(
            atPath: profile.appendingPathComponent("open-island-dsh.mjs").path
        ))
    }

    @Test
    func missingDSHHomeIsReported() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-dsh-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = DSHIntegrationManager(dshHome: home)
        #expect(manager.status().dshHomeExists == false)
        #expect(throws: DSHIntegrationError.dshNotFound) {
            try manager.install(pluginSourceData: Data())
        }
    }
}
