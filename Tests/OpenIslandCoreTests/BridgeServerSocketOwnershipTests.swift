import Darwin
import Foundation
import Testing
@testable import OpenIslandCore

struct BridgeServerSocketOwnershipTests {
    @Test
    func secondServerCannotStealALiveSocket() throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let first = BridgeServer(socketURL: socketURL)
        try first.start()
        defer {
            first.stop()
            try? FileManager.default.removeItem(at: socketURL)
        }

        let second = BridgeServer(socketURL: socketURL)
        do {
            try second.start()
            Issue.record("Expected the second server to refuse the live socket")
            second.stop()
        } catch let error as BridgeTransportError {
            guard case .bridgeAlreadyRunning = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test
    func staleSocketFileIsReclaimed() throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()

        // Create a socket file without a listener, then close it. The path
        // remains on disk, which is exactly the crash-leftover case.
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            Issue.record("Could not create a test socket")
            return
        }
        try withUnixSocketAddress(path: socketURL.path) { address, length in
            guard Darwin.bind(descriptor, address, length) == 0 else {
                throw BridgeTransportError.systemCallFailed("bind", errno)
            }
        }
        close(descriptor)
        #expect(FileManager.default.fileExists(atPath: socketURL.path))

        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        server.stop()
        try? FileManager.default.removeItem(at: socketURL)
    }
}
