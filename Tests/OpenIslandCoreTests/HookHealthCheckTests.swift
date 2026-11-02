import Foundation
import Testing
@testable import OpenIslandCore

struct HookHealthCheckTests {
    @Test
    func claudeReportsHooksMissingFromConfigWhenManifestExistsWithoutHooks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-health-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let manifestURL = tempDir.appendingPathComponent(ClaudeHookInstallerManifest.fileName)

        // Write settings.json with NO hooks
        try #"{"env":{"FOO":"BAR"}}"#.write(to: settingsURL, atomically: true, encoding: .utf8)

        // Write manifest
        let manifest = ClaudeHookInstallerManifest(hookCommand: "'/bin/echo' --source claude")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        let binaryURL = URL(fileURLWithPath: "/bin/echo")
        let report = HookHealthCheck.checkClaude(
            claudeDirectory: tempDir,
            hooksBinaryURL: binaryURL
        )

        let hasMissingIssue = report.issues.contains { issue in
            if case .hooksMissingFromConfig = issue { return true }
            return false
        }
        #expect(hasMissingIssue)
        #expect(report.repairableIssues.contains { issue in
            if case .hooksMissingFromConfig = issue { return true }
            return false
        })
    }

    @Test
    func codexReportsHooksMissingFromConfigWhenManifestExistsWithoutHooks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-health-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hooksURL = tempDir.appendingPathComponent("hooks.json")
        let manifestURL = tempDir.appendingPathComponent(CodexHookInstallerManifest.fileName)

        // Write hooks.json with NO hooks
        try #"{"hooks":[]}"#.write(to: hooksURL, atomically: true, encoding: .utf8)

        // Write manifest
        let manifest = CodexHookInstallerManifest(
            hookCommand: "'/bin/echo' --source codex",
            enabledCodexHooksFeature: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        let binaryURL = URL(fileURLWithPath: "/bin/echo")
        let report = HookHealthCheck.checkCodex(
            codexDirectory: tempDir,
            hooksBinaryURL: binaryURL
        )

        let hasMissingIssue = report.issues.contains { issue in
            if case .hooksMissingFromConfig = issue { return true }
            return false
        }
        #expect(hasMissingIssue)
    }

    @Test
    func claudeReportsHealthyWhenHooksAndManifestBothExist() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-health-claude-healthy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let binaryURL = URL(fileURLWithPath: "/bin/echo")
        let manager = ClaudeHookInstallationManager(
            claudeDirectory: tempDir,
            managedHooksBinaryURL: tempDir.appendingPathComponent("bin/OpenIslandHooks")
        )
        try manager.install(hooksBinaryURL: binaryURL)

        let report = HookHealthCheck.checkClaude(
            claudeDirectory: tempDir,
            hooksBinaryURL: binaryURL
        )

        let hasMissingIssue = report.issues.contains { issue in
            if case .hooksMissingFromConfig = issue { return true }
            return false
        }
        #expect(!hasMissingIssue)
    }
}
