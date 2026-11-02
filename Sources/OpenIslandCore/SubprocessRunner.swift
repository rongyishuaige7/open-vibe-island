import Darwin
import Foundation

/// Synchronous helper for short-lived subprocesses on paths that must never
/// block indefinitely.
///
/// Managed agent hooks run synchronously in front of the agent's tool loop.
/// A wedged `osascript` (TCC prompt, unresponsive terminal) must not be able
/// to hold the agent hostage, so every call gets a hard timeout and the child
/// is terminated when it expires.
///
/// Output is redirected to private temporary files instead of pipes. A child
/// that writes more than a pipe buffer can otherwise deadlock the parent while
/// it waits for exit, and Foundation's `FileHandle` is not safe to close and
/// read concurrently. Regular files avoid both failure modes.
public enum SubprocessRunner {
    public struct Output: Sendable, Equatable {
        public let terminationStatus: Int32
        public let stdout: String
        public let stderr: String

        public init(terminationStatus: Int32, stdout: String, stderr: String) {
            self.terminationStatus = terminationStatus
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// Runs `executableURL` with `arguments`, returning `nil` when the process
    /// cannot be launched or does not finish within `timeout` seconds.
    @discardableResult
    public static func run(
        executableURL: URL,
        arguments: [String] = [],
        timeout: TimeInterval = 2
    ) -> Output? {
        guard let stdoutFile = TemporaryFile.make(),
              let stderrFile = TemporaryFile.make() else {
            return nil
        }
        defer {
            stdoutFile.remove()
            stderrFile.remove()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutFile.writeHandle
        process.standardError = stderrFile.writeHandle

        let terminationGroup = DispatchGroup()
        terminationGroup.enter()
        process.terminationHandler = { _ in
            terminationGroup.leave()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if terminationGroup.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if terminationGroup.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminationGroup.wait(timeout: .now() + 0.2)
            }
            return nil
        }

        return Output(
            terminationStatus: process.terminationStatus,
            stdout: stdoutFile.readString(),
            stderr: stderrFile.readString()
        )
    }

    /// A uniquely named, user-private temporary file used for child output.
    private struct TemporaryFile {
        let path: String
        let writeHandle: FileHandle

        static func make() -> TemporaryFile? {
            let template = NSTemporaryDirectory() + "open-island-subprocess-XXXXXX"
            var mutableTemplate = Array(template.utf8CString)
            let fileDescriptor = mkstemp(&mutableTemplate)
            guard fileDescriptor >= 0 else {
                return nil
            }

            _ = fchmod(fileDescriptor, S_IRUSR | S_IWUSR)

            let path = String(cString: mutableTemplate)
            return TemporaryFile(
                path: path,
                writeHandle: FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
            )
        }

        func readString() -> String {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                return ""
            }
            return String(data: data, encoding: .utf8) ?? ""
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
