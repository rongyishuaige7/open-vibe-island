import Darwin
import Foundation

/// Sends one focus request to the PI Desktop plugin's local socket.
///
/// PI Desktop has no URL scheme, so focusing a specific conversation needs the
/// plugin: it listens on a Unix socket beside the bridge socket and calls
/// `desktop.invoke("session/open", [id])`. Everything here is best-effort — a
/// missing plugin, a closed socket or a slow app just returns `false` and the
/// caller falls back to activating the app.
public enum PiDesktopFocusClient {
    public static var commandSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenIsland/pi-desktop-plugin.sock")
            .path
    }

    public static func focus(
        sessionID: String,
        socketPath: String = PiDesktopFocusClient.commandSocketPath,
        timeout: TimeInterval = 0.5
    ) -> Bool {
        let sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else {
            return false
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }

        try? disableSocketSigPipe(descriptor)
        applyTimeout(descriptor, seconds: timeout)

        do {
            try withUnixSocketAddress(path: socketPath) { address, length in
                guard Darwin.connect(descriptor, address, length) != -1 else {
                    throw BridgeTransportError.systemCallFailed("connect", errno)
                }
            }

            var data = try JSONSerialization.data(
                withJSONObject: ["command": "focus", "sessionID": sessionID]
            )
            data.append(UInt8(ascii: "\n"))
            try writeAll(data, to: descriptor)
            return readAcknowledgement(from: descriptor)
        } catch {
            return false
        }
    }

    private static func applyTimeout(_ descriptor: Int32, seconds: TimeInterval) {
        let whole = Int(seconds)
        var value = timeval(
            tv_sec: whole,
            tv_usec: Int32((seconds - Double(whole)) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, size)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, size)
    }

    private static func readAcknowledgement(from descriptor: Int32) -> Bool {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 512)

        while buffer.count < 4_096 {
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                if buffer.contains(UInt8(ascii: "\n")) {
                    break
                }
                continue
            }
            if count == -1, errno == EINTR {
                continue
            }
            break
        }

        guard let line = String(data: buffer, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .first,
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return false
        }
        return (object["ok"] as? Bool) == true
    }
}
