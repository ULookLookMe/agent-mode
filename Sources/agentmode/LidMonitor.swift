import AgentModeCore
import Foundation
import IOKit

/// The lid (design §8.4): `IOPMrootDomain` posts `kIOPMMessageClamshellStateChange` to general-interest
/// clients. The message is only a trigger; `AppleClamshellState` is always read again (plan "Hechos de
/// la fase Navigate"). No polling.
@MainActor
final class LidMonitor {
    /// `kIOPMMessageClamshellStateChange`; the C macro that builds it is not imported into Swift.
    nonisolated static let clamshellStateChange: UInt32 = 0xE003_4100

    private let emit: @MainActor (Event) -> Void
    private var port: IONotificationPortRef?
    private var notification: io_object_t = IO_OBJECT_NULL
    private(set) var closed: Bool?

    init(emit: @escaping @MainActor (Event) -> Void) {
        self.emit = emit
    }

    func start() {
        refresh()
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else {
            Log.info("lid: IOPMrootDomain not found, lid changes will not be seen")
            return
        }
        defer { IOObjectRelease(root) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.info("lid: IONotificationPortCreate failed, lid changes will not be seen")
            return
        }
        self.port = port
        CFRunLoopAddSource(
            CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        // The callback runs on the main run loop, where the port's source was added.
        let result = IOServiceAddInterestNotification(
            port,
            root,
            kIOGeneralInterest,
            { refcon, _, messageType, _ in
                guard let refcon, messageType == LidMonitor.clamshellStateChange else { return }
                MainActor.assumeIsolated {
                    Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue().refresh()
                }
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &notification
        )
        if result != KERN_SUCCESS {
            Log.info("lid: IOServiceAddInterestNotification failed (\(result)), lid changes will not be seen")
        }
    }

    /// Reads `AppleClamshellState` and reports it.
    func refresh() {
        closed = RootDomain.lidClosed
        if let closed {
            emit(.lid(closed: closed))
        } else {
            Log.info("lid: AppleClamshellState is unreadable")
        }
    }
}
