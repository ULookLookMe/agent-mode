import Foundation
import Synchronization

/// Appends timestamped lines to `~/Library/Logs/agentmode.log` and rotates it to `agentmode.log.1` at
/// 1 MB. The daemon and the CLI both write here, so each line opens, appends and closes the file:
/// a process never keeps writing into a file the other one rotated.
enum Log {
    static let rotationBytes: off_t = 1_000_000

    private struct Sink {
        var url: URL
        /// Also print each line, for dry runs and the terminal.
        var echo: Bool
    }

    private static let sink = Mutex<Sink?>(nil)
    private static let timestamp = Date.ISO8601FormatStyle(
        timeZoneSeparator: .colon,
        includingFractionalSeconds: true,
        timeZone: .current
    )

    static func configure(url: URL, echo: Bool) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        sink.withLock { $0 = Sink(url: url, echo: echo) }
    }

    static func info(_ message: String) {
        let line = "\(Date().formatted(timestamp)) [\(getpid())] \(message)\n"
        sink.withLock { sink in
            guard let sink else {
                FileHandle.standardError.write(Data(line.utf8))
                return
            }
            if sink.echo {
                FileHandle.standardOutput.write(Data(line.utf8))
            }
            append(line, to: sink.url)
        }
    }

    private static func append(_ line: String, to url: URL) {
        let path = url.path(percentEncoded: false)
        var fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size >= rotationBytes {
            close(fd)
            // rename(2) replaces the previous agentmode.log.1 atomically.
            _ = rename(path, path + ".1")
            fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return }
        }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
