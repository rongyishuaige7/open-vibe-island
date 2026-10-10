import Foundation
import SQLite3

/// Read-only connections to databases another process writes in WAL mode
/// (Antigravity's summaries, KEEPER's usage).
enum SQLiteReadOnly {
    struct OpenError: Error, Equatable {
        var message: String
    }

    /// Plain READONLY, not `immutable=1`: immutable ignores the -wal file, so
    /// recent writes would stay invisible until the next checkpoint. WAL
    /// readers don't block the writer; the busy timeout only covers a
    /// checkpoint in flight.
    ///
    /// Once the writer exits and its SQLite removes the -wal and -shm files,
    /// a read-only connection cannot create them and every read fails. With
    /// no -wal file the main file holds everything, so the fallback reopens
    /// with immutable and misses nothing. With one, the failure was something
    /// else (a busy checkpoint, say), and immutable could serve stale rows.
    static func open(path: String, busyTimeoutMilliseconds: Int32) -> Result<OpaquePointer, OpenError> {
        let failure: OpenError
        switch open(path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, busyTimeoutMilliseconds) {
        case let .success(db):
            if sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1;", nil, nil, nil) == SQLITE_OK {
                return .success(db)
            }
            failure = OpenError(message: String(cString: sqlite3_errmsg(db)))
            sqlite3_close(db)
        case let .failure(error):
            failure = error
        }

        guard !FileManager.default.fileExists(atPath: path + "-wal") else {
            return .failure(failure)
        }
        let uri = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
        return open(uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, busyTimeoutMilliseconds)
    }

    private static func open(_ filename: String, flags: Int32, _ busyTimeoutMilliseconds: Int32) -> Result<OpaquePointer, OpenError> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(filename, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            return .failure(OpenError(message: message))
        }
        sqlite3_busy_timeout(db, busyTimeoutMilliseconds)
        return .success(db)
    }
}
