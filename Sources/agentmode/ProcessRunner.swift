import Foundation
import Synchronization

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { status == 0 }

    /// What to show when the command failed: its stderr, else its stdout, else the exit status.
    var failureReason: String {
        for text in [stderr, stdout] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "exit status \(status)"
    }
}

/// Runs the external commands agentmode needs (`sudo`, `pmset`, `osascript`, `launchctl`) without a
/// shell: arguments go to the program as argv, so no text is ever interpreted.
///
/// In a dry run nothing is executed: the command is logged and reported as successful. Every external
/// command goes through here, so this is the one place a dry run is enforced.
enum ProcessRunner {
    /// Blocks the calling thread until the command exits or `timeout` passes (then it is killed).
    /// The daemon calls it only off the main thread, or while terminating. A `tracker` can refuse to
    /// start the command and can stop it while it runs.
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        tracker: CommandTracker? = nil
    ) -> ProcessResult {
        let commandLine = ([executable] + arguments).joined(separator: " ")
        if Runtime.isDryRun {
            Log.info("dry run: would run \(commandLine)")
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }

        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            if let tracker {
                guard try tracker.launch(process) else {
                    return ProcessResult(status: -1, stdout: "", stderr: "not started: agentmode is exiting")
                }
            } else {
                try process.run()
            }
        } catch {
            return ProcessResult(
                status: -1, stdout: "", stderr: "could not run \(executable): \(error.localizedDescription)")
        }

        // Both pipes drain concurrently, so a chatty child can never block on a full pipe.
        let drained = DispatchGroup()
        let stdoutData = drain(stdoutPipe.fileHandleForReading, group: drained)
        let stderrData = drain(stderrPipe.fileHandleForReading, group: drained)

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // A grandchild can keep the pipes open after the command exited; the command itself is gone.
        tracker?.exited(process.processIdentifier)
        _ = drained.wait(timeout: .now() + 1)

        let stderr = String(decoding: stderrData.value, as: UTF8.self)
        return ProcessResult(
            status: timedOut ? -1 : process.terminationStatus,
            stdout: String(decoding: stdoutData.value, as: UTF8.self),
            stderr: timedOut ? "\(commandLine) timed out after \(Int(timeout)) s. \(stderr)" : stderr
        )
    }

    /// Runs the command on a background queue. `onExit` runs there as soon as the command ends;
    /// `completion` runs afterwards on the main thread.
    static func runAsync(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        tracker: CommandTracker? = nil,
        onExit: (@Sendable () -> Void)? = nil,
        completion: @escaping @MainActor @Sendable (ProcessResult) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = run(executable, arguments, timeout: timeout, tracker: tracker)
            onExit?()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    private final class DataBox: Sendable {
        private let mutex = Mutex(Data())

        var value: Data {
            get { mutex.withLock { $0 } }
            set { mutex.withLock { $0 = newValue } }
        }
    }

    /// Output kept per pipe; the commands agentmode runs print a few bytes, so more is never needed.
    static let outputLimit = 64 * 1024

    /// Reads the pipe to its end, keeping the first `outputLimit` bytes and discarding the rest.
    private static func drain(_ handle: FileHandle, group: DispatchGroup) -> DataBox {
        let box = DataBox()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            var kept = Data()
            while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
                if kept.count < outputLimit {
                    kept.append(chunk.prefix(outputLimit - kept.count))
                }
            }
            box.value = kept
            group.leave()
        }
        return box
    }
}

/// Commands that were requested and have not finished, so the daemon can wait for them before it exits
/// and stop the rest (A1). Starting a process and `stop()` are atomic with each other, so no command
/// starts after `stop()` returned.
final class CommandTracker: Sendable {
    private struct State {
        var pending = 0
        var pids: Set<pid_t> = []
        var stopped = false
    }

    private let state = Mutex(State())

    /// Counts a command from the moment it is requested; balance with `end()` once it finished.
    func begin() {
        state.withLock { $0.pending += 1 }
    }

    func end() {
        state.withLock { $0.pending -= 1 }
    }

    /// Starts `process` unless `stop()` was called; `false` if it was not started.
    func launch(_ process: Process) throws -> Bool {
        try state.withLock { state in
            guard !state.stopped else { return false }
            try process.run()
            state.pids.insert(process.processIdentifier)
            return true
        }
    }

    func exited(_ pid: pid_t) {
        state.withLock { _ = $0.pids.remove(pid) }
    }

    /// Blocks until every requested command finished; `false` if `timeout` passed first.
    func waitUntilIdle(timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { $0.pending == 0 }
    }

    /// Blocks until no started process is alive; `false` if `timeout` passed first. After `stop()` no
    /// new one can start, so this means nothing runs any more.
    func waitUntilNoneRunning(timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { $0.pids.isEmpty }
    }

    private func wait(timeout: TimeInterval, until done: (State) -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !state.withLock({ done($0) }) {
            guard Date() < deadline else { return false }
            usleep(20_000)
        }
        return true
    }

    /// Refuses new commands and sends `signal` to the running ones; returns how many were running.
    /// `sudo` relays SIGTERM to the command it runs and exits once that command ended.
    @discardableResult
    func stop(signal: Int32) -> Int {
        state.withLock { state in
            state.stopped = true
            for pid in state.pids {
                kill(pid, signal)
            }
            return state.pids.count
        }
    }
}
