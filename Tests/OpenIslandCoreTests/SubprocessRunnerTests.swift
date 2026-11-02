import Foundation
import Testing
@testable import OpenIslandCore

struct SubprocessRunnerTests {
    @Test
    func capturesStandardOutputAndExitStatus() throws {
        let result = try #require(SubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            timeout: 2
        ))

        #expect(result.terminationStatus == 0)
        #expect(result.stdout == "hello\n")
        #expect(result.stderr.isEmpty)
    }

    @Test
    func separatesStandardError() throws {
        let result = try #require(SubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err >&2"],
            timeout: 2
        ))

        #expect(result.terminationStatus == 0)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
    }

    @Test
    func preservesNonZeroExitStatus() throws {
        let result = try #require(SubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            timeout: 2
        ))

        #expect(result.terminationStatus == 7)
    }

    @Test
    func drainsOutputLargerThanThePipeBuffer() throws {
        let result = try #require(SubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' x"],
            timeout: 3
        ))

        #expect(result.terminationStatus == 0)
        #expect(result.stdout.utf8.count == 200_000)
    }

    @Test
    func timesOutAndKillsAHangingChild() throws {
        let start = Date()
        let result = SubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeout: 0.2
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(result == nil)
        #expect(elapsed < 3)
    }

    @Test
    func returnsNilForMissingExecutable() {
        let result = SubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/definitely/not/a/real/binary"),
            timeout: 0.5
        )

        #expect(result == nil)
    }
}
