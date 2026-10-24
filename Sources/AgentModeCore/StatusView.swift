import Foundation

/// How much of the heat protection the temperature sensors back on this Mac (F-002 design §3.3).
public enum HeatProtection: String, Codable, Sendable {
    case full, limited, none

    public init(_ reading: TemperatureReading?) {
        let known = [reading?.batteryMaxC, reading?.dieAverageC].compactMap { $0 }.count
        self =
            switch known {
            case 2: .full
            case 1: .limited
            default: .none
            }
    }
}

/// What `agentmode status` and `status --json` show (F-002 design §3.3): the daemon's last snapshot merged
/// with the live intent and `SleepDisabled`. The JSON form is the public contract for integrations;
/// `status.json` stays internal.
public struct StatusView: Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var version: String
    public var mode: String
    public var pauseReasons: [PauseReason]
    public var waitingForFullWake: Bool
    public var intent: Intent
    public var daemonRunning: Bool
    public var sleepDisabled: Bool?
    public var lidClosed: Bool?
    public var internetReachable: Bool?
    public var thermalLevel: String?
    public var thermalPressure: UInt64?
    public var batteryMaxCelsius: Double?
    public var chipAverageCelsius: Double?
    public var onBattery: Bool?
    public var batteryPercent: Int?
    public var heatProtection: HeatProtection
    public var lastError: String?
    public var heartbeatAt: Date?
    public var warnings: [String]

    /// The snapshot `text()` renders, with the mode, intent and `SleepDisabled` already corrected.
    private var rendered: StatusSnapshot

    static let sleepDisabledWarning =
        "SleepDisabled is 1 but the daemon is not running; run 'agentmode off' to restore sleep"

    public static func make(
        snapshot: StatusSnapshot?, intent: Intent, liveSleepDisabled: Bool?, now: Date,
        allowUnknownTemperatures: Bool = false
    ) -> StatusView {
        let daemonRunning = snapshot?.isDaemonRunning(at: now) ?? false
        var rendered =
            snapshot
            ?? StatusSnapshot(
                state: .off, intent: intent, lidClosed: nil, internetReachable: nil, thermal: nil, temperatures: nil,
                power: nil, sleepDisabled: nil, lastError: nil, heartbeatAt: Date(timeIntervalSince1970: 0))
        // The saved intent and the live kernel value are the truth even when the daemon is down, and
        // without the daemon nothing applies the mode, so the state it saved would be stale.
        rendered.intent = intent
        rendered.sleepDisabled = liveSleepDisabled
        if !daemonRunning {
            rendered.state = .off
        }

        let mode: String
        var pauseReasons: [PauseReason] = []
        var waitingForFullWake = false
        switch rendered.state {
        case .off:
            mode = "off"
        case .active:
            mode = "active"
        case .paused(let reasons):
            mode = "paused"
            pauseReasons = PauseReason.allCases.filter(reasons.contains)
            waitingForFullWake = reasons.isEmpty
        }

        let heatProtection = HeatProtection(snapshot?.temperatures)
        var warnings: [String] = []
        if liveSleepDisabled == true && !daemonRunning {
            warnings.append(sleepDisabledWarning)
        }
        if daemonRunning,
            let clause = heatClause(heatProtection, snapshot?.temperatures, allowUnknownTemperatures)
        {
            warnings.append("heat protection is limited on this Mac: \(clause)")
        }

        return StatusView(
            schemaVersion: currentSchemaVersion,
            version: AgentModeVersion.current,
            mode: mode,
            pauseReasons: pauseReasons,
            waitingForFullWake: waitingForFullWake,
            intent: intent,
            daemonRunning: daemonRunning,
            sleepDisabled: liveSleepDisabled,
            lidClosed: snapshot?.lidClosed,
            internetReachable: snapshot?.internetReachable,
            thermalLevel: snapshot?.thermal.map { name($0.level) },
            thermalPressure: snapshot?.thermal?.pressure,
            batteryMaxCelsius: finite(snapshot?.temperatures?.batteryMaxC),
            chipAverageCelsius: finite(snapshot?.temperatures?.dieAverageC),
            onBattery: snapshot?.power?.onBattery,
            batteryPercent: snapshot?.power?.percent,
            heatProtection: heatProtection,
            lastError: snapshot?.lastError,
            heartbeatAt: snapshot?.heartbeatAt,
            warnings: warnings,
            rendered: rendered
        )
    }

    /// Sorted keys, one per line; every key is present and unknown values are `null`.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // Only finite numbers, strings, booleans and dates reach the encoder, so encoding cannot fail.
        let data = try! encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// The `status` render, then `Heat protection` after the whole `Last error` (which can span lines),
    /// `Daemon` after `Heartbeat`, and a `Warning:` line per warning.
    public func text() -> String {
        var lines: [String] = []
        for line in StatusFormatter.render(rendered).components(separatedBy: "\n") {
            if line.hasPrefix("Heartbeat:") {
                lines.append("Heat protection: \(heatProtection.rawValue)")
                lines.append(heartbeatAt == nil ? "Heartbeat: never" : line)
                lines.append("Daemon: \(daemonRunning ? "running" : "not running")")
            } else {
                lines.append(line)
            }
        }
        return (lines + warnings.map { "Warning: \($0)" }).joined(separator: "\n")
    }

    private static func heatClause(
        _ protection: HeatProtection, _ reading: TemperatureReading?, _ allowUnknownTemperatures: Bool
    ) -> String? {
        switch protection {
        case .full:
            nil
        case .limited:
            reading?.batteryMaxC == nil ? "battery temperature is unreadable" : "chip temperature is unreadable"
        case .none where allowUnknownTemperatures:
            "temperature sensors are unreadable, and allowUnknownTemperatures keeps the mode on with the lid closed"
        case .none:
            "temperature sensors are unreadable; with the lid closed and no external display the mode pauses after 2 minutes"
        }
    }

    private static func name(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        }
    }

    private static func finite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? $0 : nil }
    }
}

extension StatusView: Encodable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, version, mode, pauseReasons, waitingForFullWake, intent, daemonRunning, sleepDisabled
        case lidClosed, internetReachable, thermalLevel, thermalPressure, batteryMaxCelsius, chipAverageCelsius
        case onBattery, batteryPercent, heatProtection, lastError, heartbeatAt, warnings
    }

    /// Optionals go through `encode`, not `encodeIfPresent`, so a missing value is an explicit `null`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(version, forKey: .version)
        try container.encode(mode, forKey: .mode)
        try container.encode(pauseReasons, forKey: .pauseReasons)
        try container.encode(waitingForFullWake, forKey: .waitingForFullWake)
        try container.encode(intent, forKey: .intent)
        try container.encode(daemonRunning, forKey: .daemonRunning)
        try container.encode(sleepDisabled, forKey: .sleepDisabled)
        try container.encode(lidClosed, forKey: .lidClosed)
        try container.encode(internetReachable, forKey: .internetReachable)
        try container.encode(thermalLevel, forKey: .thermalLevel)
        try container.encode(thermalPressure, forKey: .thermalPressure)
        try container.encode(batteryMaxCelsius, forKey: .batteryMaxCelsius)
        try container.encode(chipAverageCelsius, forKey: .chipAverageCelsius)
        try container.encode(onBattery, forKey: .onBattery)
        try container.encode(batteryPercent, forKey: .batteryPercent)
        try container.encode(heatProtection, forKey: .heatProtection)
        try container.encode(lastError, forKey: .lastError)
        try container.encode(heartbeatAt, forKey: .heartbeatAt)
        try container.encode(warnings, forKey: .warnings)
    }
}
