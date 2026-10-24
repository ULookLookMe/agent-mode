import Foundation

/// Applies `SleepDisabled` with the one privileged command the sudoers rule allows (design §7, §8.3),
/// then waits for the kernel's `IOPMrootDomain` property to match, so success means the Mac really
/// changed. Also puts the Mac to sleep with `pmset sleepnow`, which needs no root.
enum SleepSettings {
    static let sudo = "/usr/bin/sudo"
    static let pmset = "/usr/bin/pmset"
    /// How long the property may take to follow a successful `pmset` (task brief: up to 5 s).
    static let verifyTimeout: TimeInterval = 5
    static let commandTimeout: TimeInterval = 10

    /// The exact rule the user creates in `/etc/sudoers.d/agentmode` (design §7).
    static var sudoersRule: String {
        "\(NSUserName()) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1"
    }

    static func arguments(_ disabled: Bool) -> [String] {
        ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"]
    }

    /// The `sudo pmset` commands `apply` started, so termination can wait for them and stop the rest:
    /// one landing after the final `disablesleep 0` would leave the Mac unable to sleep (A1).
    static let inFlight = CommandTracker()

    /// Blocking variant for the CLI and for termination. Returns `nil` on success, else the reason.
    static func applySync(_ disabled: Bool, commandTimeout: TimeInterval, verifyTimeout: TimeInterval) -> String? {
        let result = ProcessRunner.run(sudo, arguments(disabled), timeout: commandTimeout)
        guard result.succeeded else {
            return result.failureReason
        }
        guard !Runtime.isDryRun else { return nil }
        let deadline = Date(timeIntervalSinceNow: verifyTimeout)
        while RootDomain.sleepDisabled != disabled {
            guard Date() < deadline else {
                return mismatch(disabled, after: verifyTimeout)
            }
            usleep(100_000)
        }
        return nil
    }

    /// Non-blocking variant for the daemon. `completion` runs on the main thread with `nil` on success.
    static func apply(_ disabled: Bool, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        inFlight.begin()
        ProcessRunner.runAsync(
            sudo,
            arguments(disabled),
            timeout: commandTimeout,
            tracker: inFlight,
            onExit: { inFlight.end() },
            completion: { result in
                guard result.succeeded else {
                    completion(result.failureReason)
                    return
                }
                guard !Runtime.isDryRun else {
                    completion(nil)
                    return
                }
                verify(disabled, deadline: Date(timeIntervalSinceNow: verifyTimeout), completion)
            }
        )
    }

    /// For termination: lets the commands `apply` started finish for up to `grace` seconds, then stops
    /// them (SIGTERM, which `sudo` relays to `pmset`, then SIGKILL) and refuses new ones. Returns a line
    /// for the log, or `nil` when nothing was running.
    static func finishRunningCommands(grace: TimeInterval, stopTimeout: TimeInterval) -> String? {
        if inFlight.waitUntilIdle(timeout: grace) {
            inFlight.stop(signal: SIGTERM)
            return nil
        }
        let count = inFlight.stop(signal: SIGTERM)
        if inFlight.waitUntilNoneRunning(timeout: stopTimeout) {
            return "stopped \(count) SleepDisabled change(s) still running after \(grace) s"
        }
        inFlight.stop(signal: SIGKILL)
        let gone = inFlight.waitUntilNoneRunning(timeout: 0.5)
        return "killed \(count) SleepDisabled change(s) that ignored SIGTERM\(gone ? "" : "; one may still be running")"
    }

    static func sleepNow(completion: @escaping @MainActor @Sendable (ProcessResult) -> Void) {
        ProcessRunner.runAsync(pmset, ["sleepnow"], timeout: commandTimeout, completion: completion)
    }

    @MainActor
    private static func verify(
        _ disabled: Bool, deadline: Date, _ completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        if RootDomain.sleepDisabled == disabled {
            completion(nil)
        } else if Date() >= deadline {
            completion(mismatch(disabled, after: verifyTimeout))
        } else {
            MainLoop.after(0.2) { verify(disabled, deadline: deadline, completion) }
        }
    }

    /// What to log after a successful change; a dry run changed nothing.
    static func appliedMessage(_ disabled: Bool) -> String {
        Runtime.isDryRun
            ? "dry run: SleepDisabled \(disabled ? 1 : 0) not applied" : "SleepDisabled is now \(disabled ? 1 : 0)"
    }

    private static func mismatch(_ disabled: Bool, after seconds: TimeInterval) -> String {
        let live = RootDomain.sleepDisabled.map { $0 ? "1" : "0" } ?? "unreadable"
        return "SleepDisabled is \(live), not \(disabled ? 1 : 0), \(Int(seconds)) s after pmset"
    }
}

/// Serializes the daemon's `SleepDisabled` changes: one `sudo pmset` at a time, and the latest request
/// wins. Two commands racing could otherwise finish out of order and leave the wrong value (A1).
@MainActor
final class SleepSettingApplier {
    private var applying: Bool?
    private var next: Bool?
    private var whenIdle: [@MainActor () -> Void] = []
    private let onSuccess: @MainActor (Bool) -> Void
    private let onFailure: @MainActor (String) -> Void

    init(onSuccess: @escaping @MainActor (Bool) -> Void, onFailure: @escaping @MainActor (String) -> Void) {
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    var isIdle: Bool { applying == nil }

    func request(_ disabled: Bool) {
        guard let applying else {
            start(disabled)
            return
        }
        // Already applying this value: a queued different value is no longer wanted.
        next = disabled == applying ? nil : disabled
    }

    /// Runs `work` once no change is pending, such as `pmset sleepnow` after `disablesleep 0`.
    func afterPendingChanges(_ work: @escaping @MainActor () -> Void) {
        if isIdle {
            work()
        } else {
            whenIdle.append(work)
        }
    }

    private func start(_ disabled: Bool) {
        applying = disabled
        SleepSettings.apply(disabled) { [weak self] error in
            self?.finish(disabled, error: error)
        }
    }

    private func finish(_ disabled: Bool, error: String?) {
        applying = nil
        let queued = next
        next = nil
        if let error {
            onFailure(error)
        } else if queued == nil {
            onSuccess(disabled)
        }
        // `onFailure` can request a new value; that request already started it.
        if let queued, isIdle {
            start(queued)
        } else if isIdle {
            let work = whenIdle
            whenIdle.removeAll()
            for item in work { item() }
        }
    }
}
