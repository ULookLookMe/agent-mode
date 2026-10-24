import AgentModeCore
import Foundation

/// `intent.json`, `status.json` and `config.json` (plan "Restricciones globales"). Writes are atomic
/// (write to a temporary file, then rename) and dates are ISO 8601.
enum StateFiles {
    /// What the CLI saves for the daemon: the user's last `on` or `off`. The daemon writes `off` when the
    /// mode fell back to OFF by itself (design §8.3).
    struct IntentRecord: Codable, Equatable {
        var intent: Intent
        var updatedAt: Date
    }

    /// `intent.json` as read. Every atomic write gives the file a new inode, so the bytes and the inode
    /// together tell whether anyone wrote it since.
    struct IntentFile: Equatable {
        /// `nil` when the file does not exist.
        var record: IntentRecord?
        fileprivate var data: Data?
        fileprivate var inode: UInt64?

        /// A missing file means the user never turned the mode on.
        var intent: Intent { record?.intent ?? .off }
    }

    // MARK: Intent

    static func readIntent(_ runtime: Runtime) throws -> Intent {
        try readIntentFile(runtime).intent
    }

    static func readIntentFile(_ runtime: Runtime) throws -> IntentFile {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: runtime.intentURL)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return IntentFile(record: nil, data: nil, inode: nil)
        }
        defer { try? handle.close() }
        // The inode and the bytes come from the same open file, so they always match.
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw CocoaError(
                .fileReadUnknown, userInfo: [NSFilePathErrorKey: runtime.intentURL.path(percentEncoded: false)])
        }
        let data = try handle.readToEnd() ?? Data()
        return IntentFile(
            record: try decoder.decode(IntentRecord.self, from: data), data: data, inode: UInt64(info.st_ino))
    }

    /// The CLI's write; the daemon learns about it through the Darwin notification that follows.
    static func writeIntent(_ intent: Intent, _ runtime: Runtime) throws {
        try withIntentLock(runtime) {
            try writeIntentRecord(intent, runtime)
        }
    }

    /// The daemon's write: saves `intent` unless `intent.json` changed since `seen`, in which case a newer
    /// command is on its way and wins. Returns the file as written, or `nil` when it was left alone.
    static func replaceIntent(_ intent: Intent, ifUnchangedSince seen: IntentFile, _ runtime: Runtime) throws
        -> IntentFile?
    {
        try withIntentLock(runtime) {
            guard try readIntentFile(runtime) == seen else { return nil }
            try writeIntentRecord(intent, runtime)
            return try readIntentFile(runtime)
        }
    }

    private static func writeIntentRecord(_ intent: Intent, _ runtime: Runtime) throws {
        try writeAtomically(encoder.encode(IntentRecord(intent: intent, updatedAt: Date())), to: runtime.intentURL)
    }

    /// Serializes the writers of `intent.json` (the CLI and the daemon) with `flock` on `intent.lock`.
    /// Each holds it for a read and a write, a few milliseconds.
    private static func withIntentLock<T>(_ runtime: Runtime, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: runtime.stateDirectory, withIntermediateDirectories: true)
        let path = runtime.stateDirectory.appending(path: "intent.lock").path(percentEncoded: false)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
        }
        return try body()
    }

    // MARK: Status

    static func readStatus(_ runtime: Runtime) -> StatusSnapshot? {
        guard let data = try? Data(contentsOf: runtime.statusURL) else { return nil }
        return try? decoder.decode(StatusSnapshot.self, from: data)
    }

    static func writeStatus(_ snapshot: StatusSnapshot, _ runtime: Runtime) throws {
        try writeAtomically(encoder.encode(snapshot), to: runtime.statusURL)
    }

    // MARK: Config

    /// An absent file gives the defaults; an unreadable or invalid one gives the defaults and a log line.
    static func loadConfig(_ runtime: Runtime) -> AgentModeConfig {
        let url = runtime.configURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .default
        }
        let config: AgentModeConfig
        do {
            config = try decoder.decode(AgentModeConfig.self, from: Data(contentsOf: url))
        } catch {
            Log.info("config \(url.path(percentEncoded: false)) is invalid, using defaults: \(error)")
            return .default
        }
        if let problem = problem(in: config) {
            Log.info("config \(url.path(percentEncoded: false)) is invalid, using defaults: \(problem)")
            return .default
        }
        return config
    }

    /// Values that would make the daemon misbehave, such as a zero probe interval that never stops firing.
    private static func problem(in config: AgentModeConfig) -> String? {
        if config.probeURLs.isEmpty {
            return "probeURLs is empty"
        }
        let positive: [(String, Double)] = [
            ("internetTimeoutMinutes", Double(config.internetTimeoutMinutes)),
            ("probeIntervalSeconds", Double(config.probeIntervalSeconds)),
            ("thermalResumeMinutes", Double(config.thermalResumeMinutes)),
            ("batteryMaxCelsius", config.batteryMaxCelsius),
            ("dieAverageMaxCelsius", config.dieAverageMaxCelsius),
            ("dieSustainMinutes", Double(config.dieSustainMinutes)),
        ]
        if let (key, _) = positive.first(where: { $0.1 <= 0 }) {
            return "\(key) must be greater than 0"
        }
        if config.batteryFloorPercent < 0 || config.resumeMarginCelsius < 0 {
            return "batteryFloorPercent and resumeMarginCelsius must not be negative"
        }
        return nil
    }

    // MARK: Helpers

    /// ISO 8601 in UTC with milliseconds, so the daemon can tell whether a command came before or after
    /// the state it saved, even within the same second.
    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateFormat))
        }
        return encoder
    }

    /// Reads dates with or without fractional seconds, so files written before milliseconds still load.
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = (try? dateFormat.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO 8601 date: \(text)")
        }
        return decoder
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
