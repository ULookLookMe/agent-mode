import AgentModeCore
import CoreGraphics
import Foundation

/// Displays (design §8.3, §8.4, A5): reports whether an external display is in use and turns the
/// built-in panel off after the lid closes. An external display is in use when it is online, not
/// built in and not asleep (plan "Hechos de la fase Navigate").
@MainActor
final class DisplayController {
    /// After the lid closes, macOS needs about a second before `displaysleepnow` sticks (design §8.3).
    static let lidSettleDelay: TimeInterval = 1
    /// The panel must show the "display off" signature this long after the lid closed (design §8.3).
    static let verifyDelay: TimeInterval = 5

    /// The reconfiguration callback has no reliable thread; it reaches the controller through this.
    private static weak var current: DisplayController?

    private let emit: @MainActor (Event) -> Void
    /// Whether turning the panel off is still wanted when the delayed command runs.
    private let stillWanted: @MainActor () -> Bool
    private let dryRun: Bool
    private(set) var externalActive = false
    private var reported = false
    private var generation = 0

    init(dryRun: Bool, stillWanted: @escaping @MainActor () -> Bool, emit: @escaping @MainActor (Event) -> Void) {
        self.dryRun = dryRun
        self.stillWanted = stillWanted
        self.emit = emit
    }

    func start() {
        Self.current = self
        let result = CGDisplayRegisterReconfigurationCallback(
            { _, flags, _ in
                guard !flags.contains(.beginConfigurationFlag) else { return }
                // Coalesces the per-display callbacks of one change into one read on the main thread.
                MainLoop.async { DisplayController.current?.refresh() }
            }, nil)
        if result != .success {
            Log.info(
                "display: CGDisplayRegisterReconfigurationCallback failed (\(result.rawValue)), display changes are only seen on ticks"
            )
        }
        refresh()
    }

    /// Reports the external display state when it changed since the last report.
    func refresh() {
        let active = Self.externalDisplayInUse()
        guard !reported || active != externalActive else { return }
        reported = true
        externalActive = active
        emit(.externalDisplay(active: active))
    }

    /// `.turnDisplayOff`: about 1 s later `pmset displaysleepnow`; at 5 s check the built-in panel
    /// and retry once. A newer request or an opened lid cancels the pending steps.
    func turnDisplayOff() {
        generation += 1
        let generation = generation
        MainLoop.after(Self.lidSettleDelay) { [weak self] in
            self?.sleepDisplays(generation: generation, attempt: 1)
        }
    }

    private func sleepDisplays(generation: Int, attempt: Int) {
        guard generation == self.generation else { return }
        guard stillWanted() else {
            Log.info(
                "display: not turning the display off, the lid opened, an external display is in use or the mode left active"
            )
            return
        }
        ProcessRunner.runAsync(SleepSettings.pmset, ["displaysleepnow"], timeout: 10) { [weak self] result in
            if !result.succeeded {
                Log.info("display: pmset displaysleepnow failed: \(result.failureReason)")
            }
            guard let self, !self.dryRun else { return }
            let remaining = Self.verifyDelay - Self.lidSettleDelay
            MainLoop.after(remaining) { [weak self] in
                self?.verify(generation: generation, attempt: attempt)
            }
        }
    }

    private func verify(generation: Int, attempt: Int) {
        guard generation == self.generation else { return }
        switch Self.builtInAsleep() {
        case true?:
            Log.info("display: built-in display is off (attempt \(attempt))")
        case false? where attempt == 1:
            Log.info("display: built-in display is still on 5 s after the lid closed, retrying once")
            sleepDisplays(generation: generation, attempt: 2)
        case false?:
            Log.info("display: built-in display is still on after the retry")
        case nil:
            Log.info("display: built-in display not found, cannot verify that it is off")
        }
    }

    /// An online display that is not built in and not asleep.
    nonisolated static func externalDisplayInUse() -> Bool {
        onlineDisplays().contains { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsAsleep($0) == 0 }
    }

    private static func builtInAsleep() -> Bool? {
        onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }.map { CGDisplayIsAsleep($0) != 0 }
    }

    nonisolated private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
}
