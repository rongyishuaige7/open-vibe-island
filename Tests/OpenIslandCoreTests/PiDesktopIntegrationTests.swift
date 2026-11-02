import Darwin
import Foundation
import Testing
@testable import OpenIslandCore

struct PiDesktopIntegrationManagerTests {
    private func temporaryHome() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pi-desktop-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let pluginSource = Data("module.exports = {};".utf8)

    @Test
    func installWritesManifestAndEntryPoint() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = PiDesktopIntegrationManager(piDesktopHome: home)
        #expect(manager.status().pluginInstalled == false)

        let status = try manager.install(pluginSourceData: pluginSource)

        #expect(status.pluginInstalled)
        #expect(status.pluginPath == manager.pluginDirectory)
        let manifest = try Data(contentsOf: manager.pluginDirectory.appendingPathComponent("manifest.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        #expect(object["id"] as? String == PiDesktopIntegrationManager.pluginID)
        #expect(object["main"] as? String == "main.js")
        #expect(object["permissions"] as? [String] == ["desktop.control"])
        #expect(try Data(contentsOf: manager.pluginDirectory.appendingPathComponent("main.js")) == pluginSource)
    }

    @Test
    func enabledRegistryEntryMarksTheBridgeReady() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = PiDesktopIntegrationManager(piDesktopHome: home)
        try manager.install(pluginSourceData: pluginSource)
        #expect(manager.status().pluginEnabled == false)

        try writeRegistry(
            at: manager.registryURL,
            entries: [["id": PiDesktopIntegrationManager.pluginID, "enabled": true]]
        )
        let status = manager.status()
        #expect(status.pluginEnabled)
        #expect(status.supportsSessionFocus)
    }

    @Test
    func uninstallRemovesTheDirectoryAndOnlyOurRegistryEntry() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = PiDesktopIntegrationManager(piDesktopHome: home)
        try manager.install(pluginSourceData: pluginSource)
        try writeRegistry(
            at: manager.registryURL,
            entries: [
                ["id": PiDesktopIntegrationManager.pluginID, "enabled": true],
                ["id": "someone.else", "enabled": true]
            ]
        )

        let status = try manager.uninstall()

        #expect(status.pluginInstalled == false)
        #expect(FileManager.default.fileExists(atPath: manager.pluginDirectory.path) == false)
        let registry = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manager.registryURL)) as? [[String: Any]]
        )
        #expect(registry.count == 1)
        #expect(registry.first?["id"] as? String == "someone.else")
    }

    @Test
    func uninstallLeavesAnUnparseableRegistryAlone() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = PiDesktopIntegrationManager(piDesktopHome: home)
        try manager.install(pluginSourceData: pluginSource)
        let broken = Data("{not json".utf8)
        try broken.write(to: manager.registryURL)

        _ = try manager.uninstall()

        #expect(try Data(contentsOf: manager.registryURL) == broken)
        #expect(manager.status().pluginInstalled == false)
    }

    private func writeRegistry(at url: URL, entries: [[String: Any]]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: entries).write(to: url)
    }
}

struct PiDesktopFocusClientTests {
    @Test
    func returnsFalseWithoutAPluginSocket() {
        let path = NSTemporaryDirectory() + "missing-\(UUID().uuidString).sock"
        #expect(PiDesktopFocusClient.focus(sessionID: "s1", socketPath: path, timeout: 0.2) == false)
    }

    @Test
    func returnsTrueWhenThePluginAcknowledges() throws {
        let path = NSTemporaryDirectory() + "focus-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = try FakeFocusServer(path: path, reply: #"{"ok":true}"#)
        defer { server.stop() }

        #expect(PiDesktopFocusClient.focus(sessionID: "s1", socketPath: path, timeout: 1) == true)
        #expect(server.received.contains { $0.contains("\"focus\"") && $0.contains("\"s1\"") })
    }

    @Test
    func returnsFalseWhenThePluginRejects() throws {
        let path = NSTemporaryDirectory() + "focus-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = try FakeFocusServer(path: path, reply: #"{"ok":false}"#)
        defer { server.stop() }

        #expect(PiDesktopFocusClient.focus(sessionID: "s1", socketPath: path, timeout: 1) == false)
    }
}

/// Minimal Unix-socket server that answers one line of JSON.
private final class FakeFocusServer: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "pi-desktop.fake-focus-server")
    private let lock = NSLock()
    private var _received: [String] = []
    private var running = true

    var received: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _received
    }

    init(path: String, reply: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerError.socket }
        unlink(path)
        do {
            try withUnixSocketAddress(path: path) { address, length in
                guard bind(descriptor, address, length) != -1 else { throw ServerError.bind }
            }
        } catch {
            close(descriptor)
            throw error
        }
        guard listen(descriptor, 4) != -1 else {
            close(descriptor)
            throw ServerError.listen
        }

        queue.async { [weak self] in
            guard let self else { return }
            while self.isRunning {
                let client = accept(self.descriptor, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 512)
                while true {
                    let count = read(client, &chunk, chunk.count)
                    if count <= 0 { break }
                    buffer.append(contentsOf: chunk[0..<count])
                    if buffer.contains(UInt8(ascii: "\n")) { break }
                }
                if let line = String(data: buffer, encoding: .utf8) {
                    self.lock.lock()
                    self._received.append(line)
                    self.lock.unlock()
                }
                var out = Data((reply + "\n").utf8)
                _ = out.withUnsafeMutableBytes { write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        close(descriptor)
    }

    enum ServerError: Error {
        case socket
        case bind
        case listen
    }
}
