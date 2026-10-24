import AgentModeCore
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Tells a full wake from a maintenance DarkWake (design §8.4, A6). A full wake has the Graphics bit
/// of `System Capabilities` and either an open lid or an active external display
/// (`Predicates.isFullWake`). It is read when the system powers on, 10 s later, whenever the daemon
/// asks (lid or external display changes, every tick) and 10 s after a full wake starts, so the
/// engine's 10 s hold can complete without waiting for the next tick.
@MainActor
final class WakeMonitor {
    // `iokit_common_msg()` values; the C macros are not imported into Swift.
    nonisolated static let canSystemSleep: UInt32 = 0xE000_0270
    nonisolated static let systemWillSleep: UInt32 = 0xE000_0280
    nonisolated static let systemHasPoweredOn: UInt32 = 0xE000_0300
    /// Matches the engine's full-wake hold, plus a margin so the re-read lands after it.
    static let followUpDelay: TimeInterval = 10.5

    private let emit: @MainActor (Event) -> Void
    private let lidClosed: @MainActor () -> Bool?
    private let externalDisplayActive: @MainActor () -> Bool
    private var rootPort: io_connect_t = IO_OBJECT_NULL
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = IO_OBJECT_NULL
    private var lastFullWake: Bool?
    private var followUpGeneration = 0

    init(
        lidClosed: @escaping @MainActor () -> Bool?,
        externalDisplayActive: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) {
        self.lidClosed = lidClosed
        self.externalDisplayActive = externalDisplayActive
        self.emit = emit
    }

    func start() {
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notifyPort,
            { refcon, _, messageType, messageArgument in
                guard let refcon else { return }
                let argument = Int(bitPattern: messageArgument)
                // Delivered on the main run loop, where the port's source was added.
                MainActor.assumeIsolated {
                    Unmanaged<WakeMonitor>.fromOpaque(refcon).takeUnretainedValue()
                        .handle(message: messageType, argument: argument)
                }
            },
            &notifier
        )
        if rootPort != IO_OBJECT_NULL, let notifyPort {
            CFRunLoopAddSource(
                CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
        } else {
            Log.info("wake: IORegisterForSystemPower failed, wakes are only seen on ticks")
        }
        evaluate()
    }

    /// Reads the wake state and reports it. `followUp` reads it again 10 s later.
    func evaluate(followUp: Bool = false) {
        // An unknown lid counts as closed: it must never be the reason to resume (A6).
        let full = Predicates.isFullWake(
            capabilities: RootDomain.systemCapabilities,
            lidClosed: lidClosed() ?? true,
            externalDisplayActive: externalDisplayActive()
        )
        let starting = full && lastFullWake != true
        lastFullWake = full
        emit(.fullWake(full))
        if followUp || starting {
            scheduleFollowUp()
        }
    }

    private func scheduleFollowUp() {
        followUpGeneration += 1
        let generation = followUpGeneration
        MainLoop.after(Self.followUpDelay) { [weak self] in
            guard let self, generation == self.followUpGeneration else { return }
            self.evaluate()
        }
    }

    private func handle(message: UInt32, argument: Int) {
        switch message {
        case Self.canSystemSleep:
            // Never veto sleep; answer at once so macOS does not wait 30 s for us.
            IOAllowPowerChange(rootPort, argument)
        case Self.systemWillSleep:
            IOAllowPowerChange(rootPort, argument)
            lastFullWake = false
            emit(.fullWake(false))
        case Self.systemHasPoweredOn:
            Log.info(
                "wake: system powered on, capabilities \(RootDomain.systemCapabilities.map { "0x" + String($0, radix: 16) } ?? "unreadable")"
            )
            evaluate(followUp: true)
        default:
            break
        }
    }
}
