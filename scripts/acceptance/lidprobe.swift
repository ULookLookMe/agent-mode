// Acceptance sampler: records lid, display, keyboard backlight and power state once per second.
// Build: swiftc -O -o /tmp/lidprobe scripts/acceptance/lidprobe.swift
// Usage: /tmp/lidprobe <maxSeconds> [dry]
// It stops 5 s after the lid reopens, or at maxSeconds. A gap event means the Mac slept.
import CoreGraphics
import Foundation
import IOKit

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
let maxSeconds = args.count > 1 ? (Double(args[1]) ?? 600) : 600
let dryRun = args.count > 2 && args[2] == "dry"

func regProp(_ cls: String, _ key: String, namePrefix: String? = nil, builtInOnly: Bool = false) -> Any? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(iter) }
    var service = IOIteratorNext(iter)
    while service != 0 {
        defer {
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        if let prefix = namePrefix {
            let name =
                IORegistryEntryCreateCFProperty(service, "IONameMatched" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if name?.hasPrefix(prefix) != true { continue }
        }
        if builtInOnly {
            let builtIn =
                IORegistryEntryCreateCFProperty(service, "Built-In" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool
            if builtIn != true { continue }
        }
        if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        {
            return value
        }
    }
    return nil
}

// Keyboard backlight through the private CoreBrightness client.
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let kbc: NSObject? = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
typealias FloatFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
typealias BoolFn = @convention(c) (AnyObject, Selector, UInt64) -> Bool

func kbFloat(_ name: String, _ id: UInt64) -> Float? {
    guard let kbc else { return nil }
    let sel = NSSelectorFromString(name)
    guard kbc.responds(to: sel) else { return nil }
    return unsafeBitCast(kbc.method(for: sel), to: FloatFn.self)(kbc, sel, id)
}

func kbBool(_ name: String, _ id: UInt64) -> Bool? {
    guard let kbc else { return nil }
    let sel = NSSelectorFromString(name)
    guard kbc.responds(to: sel) else { return nil }
    return unsafeBitCast(kbc.method(for: sel), to: BoolFn.self)(kbc, sel, id)
}

let keyboardIDs =
    (kbc?.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeUnretainedValue() as? [NSNumber]) ?? []
let builtinKeyboard = keyboardIDs.map(\.uint64Value).first { kbBool("isKeyboardBuiltIn:", $0) == true }

func builtinDisplay() -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
}
let builtinID = builtinDisplay() ?? CGMainDisplayID()

func lidClosed() -> Bool? { regProp("IOPMrootDomain", "AppleClamshellState") as? Bool }

/// Battery power in watts; negative while discharging.
func batteryWatts() -> Float? {
    guard let mv = regProp("AppleSmartBattery", "Voltage") as? NSNumber,
        let ma = regProp("AppleSmartBattery", "InstantAmperage") as? NSNumber
    else { return nil }
    return Float(mv.doubleValue * Double(ma.int64Value) / 1_000_000)
}

func fmt(_ v: Any?) -> String {
    switch v {
    case nil: return "NA"
    case let b as Bool: return b ? "1" : "0"
    case let f as Float: return String(format: "%.3f", f)
    default: return "\(v!)"
    }
}

let clock = DateFormatter()
clock.dateFormat = "HH:mm:ss.SSS"

print(
    "time,lid_closed,sleep_disabled,cg_online,cg_active,cg_asleep,cg_active_count,iomfb_level,kbd_level,kbd_suppressed,batt_w"
)
let start = Date()
var last = start
var closedSince: Date?
var openedAfterClose: Date?
var samples = 0
while Date().timeIntervalSince(start) < maxSeconds {
    let now = Date()
    let gap = now.timeIntervalSince(last)
    if gap > 3 { print("EVENT gap \(String(format: "%.1f", gap))s before \(clock.string(from: now))") }
    last = now

    let closed = lidClosed()
    var activeIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var activeCount: UInt32 = 0
    CGGetActiveDisplayList(16, &activeIDs, &activeCount)
    let row: [Any?] = [
        clock.string(from: now), closed, regProp("IOPMrootDomain", "SleepDisabled"),
        CGDisplayIsOnline(builtinID) != 0, CGDisplayIsActive(builtinID) != 0, CGDisplayIsAsleep(builtinID) != 0,
        activeCount,
        regProp("IOMobileFramebufferShim", "IOMFBBrightnessLevel", namePrefix: "disp0"),
        builtinKeyboard.flatMap { kbFloat("backlightLevelForKeyboard:", $0) },
        builtinKeyboard.flatMap { kbBool("isBacklightSuppressedOnKeyboard:", $0) },
        batteryWatts(),
    ]
    print(row.map(fmt).joined(separator: ","))

    samples += 1
    if dryRun && samples >= 3 { break }
    if !dryRun, let closed {
        if closed {
            if closedSince == nil {
                closedSince = now
                print("EVENT lid closed at \(clock.string(from: now))")
            }
        } else if let since = closedSince, openedAfterClose == nil {
            print(
                "EVENT lid opened at \(clock.string(from: now)) after \(String(format: "%.0f", now.timeIntervalSince(since)))s closed"
            )
            openedAfterClose = now
        }
        if let opened = openedAfterClose, now.timeIntervalSince(opened) >= 5 { break }
    }
    Thread.sleep(forTimeInterval: 1)
}
print("EVENT done at \(clock.string(from: Date()))")
