import Foundation

/// Main-thread scheduling for the daemon, whose main thread runs `CFRunLoopRun()`. The main dispatch
/// queue drains on that run loop, so blocks scheduled here run on the main actor.
enum MainLoop {
    static func after(_ seconds: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { work() }
        }
    }

    static func async(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work() }
        }
    }

    /// A repeating timer on the main run loop; the first fire is `first` seconds from now.
    @discardableResult
    static func repeating(
        every interval: TimeInterval,
        first: TimeInterval,
        _ work: @escaping @MainActor @Sendable () -> Void
    ) -> Timer {
        let timer = Timer(fire: Date(timeIntervalSinceNow: first), interval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { work() }
        }
        timer.tolerance = min(interval / 10, 5)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
