import Foundation
import IOKit

/// Reads properties of `IOPMrootDomain`, the kernel's power-management root (plan "Hechos de la fase
/// Navigate"). Each read takes microseconds, so it is safe on the main thread.
enum RootDomain {
    static func property(_ key: String) -> Any? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// The live `SleepDisabled` value that `pmset -a disablesleep` sets; `nil` if unreadable.
    static var sleepDisabled: Bool? {
        (property("SleepDisabled") as? NSNumber)?.boolValue
    }

    /// `AppleClamshellState`: true when the lid is closed; `nil` if unreadable.
    static var lidClosed: Bool? {
        (property("AppleClamshellState") as? NSNumber)?.boolValue
    }

    /// `System Capabilities`: the Graphics bit is set only in a full wake; `nil` if unreadable.
    static var systemCapabilities: UInt32? {
        (property("System Capabilities") as? NSNumber)?.uint32Value
    }
}
