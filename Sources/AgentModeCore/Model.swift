import Foundation

public enum Intent: String, Codable, Sendable {
    case on, off
}

public enum PauseReason: String, Codable, CaseIterable, Comparable, Sendable {
    case noInternet, thermal, lowBattery, sensorsUnavailable

    public static func < (lhs: PauseReason, rhs: PauseReason) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// An empty pause set means every condition recovered and the mode waits for a full wake.
public enum ModeState: Equatable, Codable, Sendable {
    case off, active
    case paused(Set<PauseReason>)
}

public enum Notice: Equatable, Sendable {
    case activated
    case paused(Set<PauseReason>)
    case resumed, deactivated
    case error(String)
}

public enum ThermalLevel: Int, Codable, Sendable {
    case nominal, fair, serious, critical
}

public struct ThermalReading: Equatable, Codable, Sendable {
    public var level: ThermalLevel
    public var pressure: UInt64

    public init(level: ThermalLevel, pressure: UInt64) {
        self.level = level
        self.pressure = pressure
    }
}

public struct PowerReading: Equatable, Codable, Sendable {
    public var onBattery: Bool
    public var percent: Int?

    public init(onBattery: Bool, percent: Int?) {
        self.onBattery = onBattery
        self.percent = percent
    }
}

public struct SensorSample: Equatable, Sendable {
    public var name: String
    public var celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

public struct TemperatureReading: Equatable, Codable, Sendable {
    public var batteryMaxC: Double?
    public var dieAverageC: Double?

    public init(batteryMaxC: Double?, dieAverageC: Double?) {
        self.batteryMaxC = batteryMaxC
        self.dieAverageC = dieAverageC
    }
}

public enum Event: Equatable, Sendable {
    /// The state the previous daemon saved, fed before `.startup` so a restart keeps a pause (design §8.3).
    /// Ignored once the engine has started.
    case savedState(ModeState)
    /// Reconciles `SleepDisabled` with the intent. Lid, external display, power, heat and wake readings
    /// fed before it count, so a restart never re-activates in a DarkWake (A6).
    case startup(intent: Intent, sleepDisabled: Bool?)
    case intent(Intent)
    case lid(closed: Bool)
    case externalDisplay(active: Bool)
    case probe(reachable: Bool)
    case thermal(ThermalReading)
    case temperatures(TemperatureReading)
    case power(PowerReading)
    case fullWake(Bool)
    case tick(sleepDisabled: Bool?)
    case applyFailed(String)
    case terminating
}

public enum Action: Equatable, Sendable {
    /// `sudo -n /usr/bin/pmset -a disablesleep 0|1`, then verify.
    case setSleepDisabled(Bool)
    /// `pmset sleepnow`.
    case sleepNow
    /// About 1 s later `pmset displaysleepnow`; verify at 5 s; retry once.
    case turnDisplayOff
    case notify(Notice)
    case log(String)
}
