import AgentModeCore
import Foundation
import IOKit.ps

/// Power source and battery charge (design §8.4, P3) through IOPowerSources and its run-loop
/// notification. An unreadable source is not reported at all: unknown power never pauses or resumes.
@MainActor
final class PowerMonitor {
    private let emit: @MainActor (Event) -> Void
    private var source: CFRunLoopSource?
    private var last: PowerReading?
    private var reportedUnreadable = false

    init(emit: @escaping @MainActor (Event) -> Void) {
        self.emit = emit
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let created = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                // Delivered on the main run loop, where the source was added.
                MainActor.assumeIsolated {
                    Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
                }
            },
            context
        )
        if let source = created?.takeRetainedValue() {
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        } else {
            Log.info("power: IOPSNotificationCreateRunLoopSource failed, power changes are only seen on ticks")
        }
        refresh()
    }

    /// Reports the reading when it changed since the last report.
    func refresh() {
        guard let reading = Self.read() else {
            if !reportedUnreadable {
                Log.info("power: power source is unreadable")
                reportedUnreadable = true
            }
            return
        }
        reportedUnreadable = false
        guard reading != last else { return }
        last = reading
        emit(.power(reading))
    }

    private static func read() -> PowerReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else {
            return nil
        }
        var percent: Int?
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int
            else {
                continue
            }
            percent = Predicates.batteryPercent(current: current, max: maximum)
            break
        }
        return PowerReading(onBattery: providing == kIOPMBatteryPowerKey, percent: percent)
    }
}
