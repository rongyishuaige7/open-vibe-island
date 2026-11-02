import Testing
@testable import OpenIslandCore

struct WatchHTTPEndpointTests {
    @Test
    func activeSessionCountIsClampedAndReadableAcrossThreads() async {
        let endpoint = WatchHTTPEndpoint()

        endpoint.updateActiveSessionCount(3)
        #expect(endpoint.activeSessionCountForTests() == 3)

        await Task.detached {
            endpoint.updateActiveSessionCount(-4)
        }.value
        #expect(endpoint.activeSessionCountForTests() == 0)
    }

    @Test
    func connectedClientCountStartsAtZero() {
        #expect(WatchHTTPEndpoint().connectedClientCount() == 0)
    }
}
