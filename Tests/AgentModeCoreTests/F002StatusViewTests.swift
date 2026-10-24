import Foundation
import Testing

@testable import AgentModeCore

// F-002 design §3.3: the status view behind `agentmode status` and `status --json`.
// Contract tests written from the spec and the public interfaces only. All readings are fictitious.

private let heartbeat = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// When the view is built, relative to the snapshot's heartbeat.
enum F002Liveness: String, CaseIterable, Sendable {
    /// No snapshot at all.
    case noSnapshot
    /// Heartbeat 119 s old: the daemon runs.
    case fresh
    /// Heartbeat 120 s old: the daemon is gone.
    case stale
    /// Fresh heartbeat, but the daemon recorded that it stopped.
    case stopped

    var running: Bool { self == .fresh }

    var now: Date {
        switch self {
        case .noSnapshot, .stopped: heartbeat.addingTimeInterval(1)
        case .fresh: heartbeat.addingTimeInterval(119)
        case .stale: heartbeat.addingTimeInterval(120)
        }
    }
}

private func snapshot(
    _ liveness: F002Liveness = .fresh,
    state: ModeState = .active,
    intent: Intent = .on,
    lidClosed: Bool? = true,
    internetReachable: Bool? = false,
    thermal: ThermalReading? = ThermalReading(level: .serious, pressure: 3),
    temperatures: TemperatureReading? = TemperatureReading(batteryMaxC: 36.5, dieAverageC: 51.25),
    power: PowerReading? = PowerReading(onBattery: true, percent: 42),
    sleepDisabled: Bool? = true,
    lastError: String? = nil
) -> StatusSnapshot? {
    guard liveness != .noSnapshot else { return nil }
    return StatusSnapshot(
        state: state,
        intent: intent,
        lidClosed: lidClosed,
        internetReachable: internetReachable,
        thermal: thermal,
        temperatures: temperatures,
        power: power,
        sleepDisabled: sleepDisabled,
        lastError: lastError,
        heartbeatAt: heartbeat,
        stoppedAt: liveness == .stopped ? heartbeat : nil
    )
}

private let sleepDisabledWarning =
    "SleepDisabled is 1 but the daemon is not running; run 'agentmode off' to restore sleep"
private let heatPrefix = "heat protection is limited on this Mac:"
private let batteryClause = "battery temperature is unreadable"
private let chipClause = "chip temperature is unreadable"
private let sensorsClause =
    "temperature sensors are unreadable; with the lid closed and no external display the mode pauses after 2 minutes"

private let allJSONKeys: Set<String> = [
    "schemaVersion", "version", "mode", "pauseReasons", "waitingForFullWake", "intent", "daemonRunning",
    "sleepDisabled", "lidClosed", "internetReachable", "thermalLevel", "thermalPressure", "batteryMaxCelsius",
    "chipAverageCelsius", "onBattery", "batteryPercent", "heatProtection", "lastError", "heartbeatAt", "warnings",
]

private func parseObject(_ json: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    return try #require(object as? [String: Any], "json() is not a JSON object:\n\(json)")
}

private func isJSONBool(_ value: Any?) -> Bool {
    guard let value else { return false }
    return CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID()
}

private func parseISO8601(_ string: String) -> Date? {
    if let date = ISO8601DateFormatter().date(from: string) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string)
}

/// The lines `text()` must print: `StatusFormatter.render` of `base`, with `Heat protection` right after the
/// `Last error` line, `Daemon` right after the `Heartbeat` line, and one `Warning:` line per warning at the end.
private func expectedLines(
    rendering base: StatusSnapshot,
    heartbeatNever: Bool,
    heat: String,
    daemon: String,
    warnings: [String]
) throws -> [String] {
    var lines = StatusFormatter.render(base).trimmingCharacters(in: .newlines)
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if heartbeatNever {
        let index = try #require(lines.firstIndex { $0.hasPrefix("Heartbeat:") }, "render has a Heartbeat line")
        lines[index] = "Heartbeat: never"
    }
    let lastError = try #require(lines.lastIndex { $0.hasPrefix("Last error") }, "render has a Last error line")
    lines.insert("Heat protection: \(heat)", at: lastError + 1)
    let heartbeatLine = try #require(lines.lastIndex { $0.hasPrefix("Heartbeat:") }, "render has a Heartbeat line")
    lines.insert("Daemon: \(daemon)", at: heartbeatLine + 1)
    return lines + warnings.map { "Warning: \($0)" }
}

private func textLines(_ view: StatusView) -> [String] {
    view.text().trimmingCharacters(in: .newlines)
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

@Suite struct F002StatusViewTests {

    // MARK: - HeatProtection

    @Test(
        "F-002 · E24 · heat protection is full with both sensors, limited with one, none with neither",
        arguments: [
            (TemperatureReading(batteryMaxC: 36.5, dieAverageC: 51.25), HeatProtection.full),
            (TemperatureReading(batteryMaxC: 36.5, dieAverageC: nil), .limited),
            (TemperatureReading(batteryMaxC: nil, dieAverageC: 51.25), .limited),
            (TemperatureReading(batteryMaxC: nil, dieAverageC: nil), .none),
            (nil, .none),
        ] as [(TemperatureReading?, HeatProtection)]
    )
    func heatProtectionFollowsKnownSensors(reading: TemperatureReading?, expected: HeatProtection) {
        #expect(HeatProtection(reading) == expected)
    }

    // MARK: - StatusView.make

    @Test("F-002 · E25 · the view carries schema version 1 and the release version")
    func viewCarriesSchemaAndVersion() {
        #expect(StatusView.currentSchemaVersion == 1)
        for liveness in F002Liveness.allCases {
            let view = StatusView.make(
                snapshot: snapshot(liveness), intent: .on, liveSleepDisabled: true, now: liveness.now)
            #expect(view.schemaVersion == 1, "\(liveness)")
            #expect(view.version == AgentModeVersion.current, "\(liveness)")
        }
    }

    @Test(
        "F-002 · E26 · daemonRunning is the snapshot's liveness, false without a snapshot",
        arguments: F002Liveness.allCases
    )
    func daemonRunningFollowsLiveness(liveness: F002Liveness) {
        let view = StatusView.make(
            snapshot: snapshot(liveness), intent: .on, liveSleepDisabled: true, now: liveness.now)
        #expect(view.daemonRunning == liveness.running)
    }

    @Test(
        "F-002 · E27 · with the daemon not running the mode is off, without reasons or a wait",
        arguments: [ModeState.active, .paused([.thermal]), .paused([]), .off], [F002Liveness.stale, .stopped]
    )
    func stoppedDaemonShowsOff(state: ModeState, liveness: F002Liveness) {
        let view = StatusView.make(
            snapshot: snapshot(liveness, state: state), intent: .on, liveSleepDisabled: false, now: liveness.now)
        #expect(view.mode == "off")
        #expect(view.pauseReasons == [])
        #expect(view.waitingForFullWake == false)
    }

    @Test(
        "F-002 · E28 · with the daemon running the mode comes from the snapshot, reasons in allCases order",
        arguments: [
            (ModeState.off, "off", [], false),
            (.active, "active", [], false),
            (.paused([.lowBattery, .noInternet]), "paused", [.noInternet, .lowBattery], false),
            (.paused([.sensorsUnavailable, .thermal]), "paused", [.thermal, .sensorsUnavailable], false),
            (
                .paused([.thermal, .sensorsUnavailable, .noInternet, .lowBattery]), "paused",
                [.noInternet, .thermal, .lowBattery, .sensorsUnavailable], false
            ),
            (.paused([]), "paused", [], true),
        ] as [(ModeState, String, [PauseReason], Bool)]
    )
    func runningDaemonShowsSnapshotMode(state: ModeState, mode: String, reasons: [PauseReason], waiting: Bool) {
        let view = StatusView.make(
            snapshot: snapshot(.fresh, state: state), intent: .on, liveSleepDisabled: true, now: F002Liveness.fresh.now)
        #expect(view.mode == mode)
        #expect(view.pauseReasons == reasons)
        #expect(view.waitingForFullWake == waiting)
    }

    @Test(
        "F-002 · E29 · intent and sleepDisabled come from the arguments, never from the snapshot",
        arguments: [
            (Intent.on, Intent.off, true, false),
            (.off, .on, false, true),
            (.on, .off, true, nil),
        ] as [(snapshotIntent: Intent, intent: Intent, snapshotSleep: Bool?, liveSleep: Bool?)],
        F002Liveness.allCases
    )
    func intentAndSleepDisabledComeFromArguments(
        values: (snapshotIntent: Intent, intent: Intent, snapshotSleep: Bool?, liveSleep: Bool?),
        liveness: F002Liveness
    ) {
        let view = StatusView.make(
            snapshot: snapshot(liveness, intent: values.snapshotIntent, sleepDisabled: values.snapshotSleep),
            intent: values.intent, liveSleepDisabled: values.liveSleep, now: liveness.now)
        #expect(view.intent == values.intent)
        #expect(view.sleepDisabled == values.liveSleep)
    }

    @Test(
        "F-002 · E30 · readings come from the snapshot even when the daemon is not running",
        arguments: [F002Liveness.fresh, .stale, .stopped]
    )
    func readingsComeFromSnapshot(liveness: F002Liveness) {
        let view = StatusView.make(
            snapshot: snapshot(liveness, lastError: "pmset: fictional failure"), intent: .on,
            liveSleepDisabled: true, now: liveness.now)
        #expect(view.lidClosed == true)
        #expect(view.internetReachable == false)
        #expect(view.thermalLevel == "serious")
        #expect(view.thermalPressure == 3)
        #expect(view.batteryMaxCelsius == 36.5)
        #expect(view.chipAverageCelsius == 51.25)
        #expect(view.onBattery == true)
        #expect(view.batteryPercent == 42)
        #expect(view.lastError == "pmset: fictional failure")
        #expect(view.heatProtection == .full)
        #expect(view.heartbeatAt == heartbeat)
    }

    @Test(
        "F-002 · E31 · thermalLevel is named nominal, fair, serious or critical",
        arguments: [
            (ThermalLevel.nominal, "nominal"), (.fair, "fair"), (.serious, "serious"), (.critical, "critical"),
        ]
    )
    func thermalLevelNames(level: ThermalLevel, name: String) {
        let view = StatusView.make(
            snapshot: snapshot(thermal: ThermalReading(level: level, pressure: 0)), intent: .on,
            liveSleepDisabled: true, now: F002Liveness.fresh.now)
        #expect(view.thermalLevel == name)
    }

    @Test("F-002 · E32 · without a snapshot every reading and the heartbeat are nil, the mode is off")
    func noSnapshotLeavesReadingsUnknown() {
        let view = StatusView.make(snapshot: nil, intent: .on, liveSleepDisabled: false, now: heartbeat)
        #expect(view.daemonRunning == false)
        #expect(view.mode == "off")
        #expect(view.pauseReasons == [])
        #expect(view.waitingForFullWake == false)
        #expect(view.lidClosed == nil)
        #expect(view.internetReachable == nil)
        #expect(view.thermalLevel == nil)
        #expect(view.thermalPressure == nil)
        #expect(view.batteryMaxCelsius == nil)
        #expect(view.chipAverageCelsius == nil)
        #expect(view.onBattery == nil)
        #expect(view.batteryPercent == nil)
        #expect(view.lastError == nil)
        #expect(view.heartbeatAt == nil)
        #expect(view.heatProtection == .none)
        #expect(view.schemaVersion == 1)
    }

    static let heatCases: [(temperatures: TemperatureReading?, expected: HeatProtection)] = [
        (TemperatureReading(batteryMaxC: 36.5, dieAverageC: 51.25), .full),
        (TemperatureReading(batteryMaxC: nil, dieAverageC: 51.25), .limited),
        (TemperatureReading(batteryMaxC: nil, dieAverageC: nil), .none),
        (nil, .none),
    ]

    @Test(
        "F-002 · E33 · heatProtection comes from the snapshot's temperatures",
        arguments: heatCases, [F002Liveness.fresh, .stale]
    )
    func heatProtectionComesFromSnapshot(
        heat: (temperatures: TemperatureReading?, expected: HeatProtection), liveness: F002Liveness
    ) {
        let view = StatusView.make(
            snapshot: snapshot(liveness, temperatures: heat.temperatures), intent: .on, liveSleepDisabled: false,
            now: liveness.now)
        #expect(view.heatProtection == heat.expected)
        #expect(view.mode == (liveness.running ? "active" : "off"))
    }

    // MARK: - Warnings

    @Test(
        "F-002 · E34 · SleepDisabled 1 with the daemon not running warns to run `agentmode off`, and only that",
        arguments: [F002Liveness.noSnapshot, .stale, .stopped]
    )
    func sleepDisabledWithoutDaemonWarns(liveness: F002Liveness) {
        // Unreadable sensors too: the heat warning needs a running daemon, so it must not appear here.
        let view = StatusView.make(
            snapshot: snapshot(liveness, temperatures: TemperatureReading(batteryMaxC: nil, dieAverageC: nil)),
            intent: .on, liveSleepDisabled: true, now: liveness.now)
        #expect(view.warnings == [sleepDisabledWarning])
    }

    @Test(
        "F-002 · E35 · no warning when SleepDisabled is not 1, or the daemon runs with full heat protection",
        arguments: [
            (false, F002Liveness.stale), (nil, .stale), (false, .noSnapshot), (nil, .noSnapshot), (true, .fresh),
            (false, .fresh),
        ] as [(Bool?, F002Liveness)]
    )
    func noWarningOtherwise(liveSleepDisabled: Bool?, liveness: F002Liveness) {
        let view = StatusView.make(
            snapshot: snapshot(liveness), intent: .on, liveSleepDisabled: liveSleepDisabled, now: liveness.now)
        #expect(view.warnings == [])
    }

    static let limitedCases: [(temperatures: TemperatureReading?, clause: String)] = [
        (TemperatureReading(batteryMaxC: nil, dieAverageC: 51.25), batteryClause),
        (TemperatureReading(batteryMaxC: 36.5, dieAverageC: nil), chipClause),
        (TemperatureReading(batteryMaxC: nil, dieAverageC: nil), sensorsClause),
        (nil, sensorsClause),
    ]

    static let liveSleepValues: [Bool?] = [true, false, nil]

    @Test(
        "F-002 · E36 · a running daemon without full heat protection gives one heat warning naming what is unreadable",
        arguments: limitedCases, liveSleepValues
    )
    func limitedHeatProtectionWarns(
        limited: (temperatures: TemperatureReading?, clause: String), liveSleepDisabled: Bool?
    ) throws {
        let view = StatusView.make(
            snapshot: snapshot(.fresh, temperatures: limited.temperatures), intent: .on,
            liveSleepDisabled: liveSleepDisabled, now: F002Liveness.fresh.now)
        try #require(view.warnings.count == 1, "warnings: \(view.warnings)")
        let warning = view.warnings[0]
        #expect(warning.hasPrefix(heatPrefix), "warning: \(warning)")
        #expect(
            warning.dropFirst(heatPrefix.count).trimmingCharacters(in: .whitespaces) == limited.clause,
            "warning: \(warning)")
    }

    // MARK: - json()

    enum UnknownCase: String, CaseIterable, Sendable {
        case noSnapshot, runningWithUnknownReadings
    }

    @Test(
        "F-002 · E37 · json() always has every key, with null for what is unknown",
        arguments: UnknownCase.allCases
    )
    func jsonHasEveryKeyWithNulls(unknown: UnknownCase) throws {
        let view: StatusView
        var nullKeys: Set<String> = [
            "sleepDisabled", "lidClosed", "internetReachable", "thermalLevel", "thermalPressure",
            "batteryMaxCelsius", "chipAverageCelsius", "onBattery", "batteryPercent", "lastError",
        ]
        switch unknown {
        case .noSnapshot:
            view = StatusView.make(snapshot: nil, intent: .on, liveSleepDisabled: nil, now: heartbeat)
            nullKeys.insert("heartbeatAt")
        case .runningWithUnknownReadings:
            let empty = snapshot(
                .fresh, state: .paused([]), lidClosed: nil, internetReachable: nil, thermal: nil, temperatures: nil,
                power: nil, sleepDisabled: nil, lastError: nil)
            view = StatusView.make(snapshot: empty, intent: .on, liveSleepDisabled: nil, now: F002Liveness.fresh.now)
        }

        let object = try parseObject(view.json())
        #expect(Set(object.keys) == allJSONKeys)
        for key in nullKeys {
            #expect(object[key] is NSNull, "\(key) should be null, got \(String(describing: object[key]))")
        }
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["version"] as? String == AgentModeVersion.current)
        #expect(object["intent"] as? String == "on")
        #expect(object["heatProtection"] as? String == "none")
        #expect(isJSONBool(object["daemonRunning"]))
        #expect(isJSONBool(object["waitingForFullWake"]))
        #expect(object["warnings"] as? [String] == view.warnings)
        switch unknown {
        case .noSnapshot:
            #expect(object["mode"] as? String == "off")
            #expect(object["daemonRunning"] as? Bool == false)
            #expect(object["pauseReasons"] as? [String] == [])
            #expect(object["waitingForFullWake"] as? Bool == false)
        case .runningWithUnknownReadings:
            #expect(object["mode"] as? String == "paused")
            #expect(object["daemonRunning"] as? Bool == true)
            #expect(object["pauseReasons"] as? [String] == [])
            #expect(object["waitingForFullWake"] as? Bool == true)
            #expect(object["heartbeatAt"] is String)
            #expect((object["warnings"] as? [String])?.count == 1)
        }
    }

    @Test("F-002 · E38 · json() carries every value, reasons as raw values and the heartbeat as ISO 8601 UTC")
    func jsonCarriesEveryValue() throws {
        let view = StatusView.make(
            snapshot: snapshot(
                .fresh, state: .paused([.lowBattery, .noInternet]), intent: .off, sleepDisabled: false,
                lastError: "pmset: fictional failure"),
            intent: .on, liveSleepDisabled: true, now: F002Liveness.fresh.now)
        let object = try parseObject(view.json())

        #expect(Set(object.keys) == allJSONKeys)
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["version"] as? String == AgentModeVersion.current)
        #expect(object["mode"] as? String == "paused")
        #expect(object["pauseReasons"] as? [String] == ["noInternet", "lowBattery"])
        #expect(object["intent"] as? String == "on")
        #expect(object["sleepDisabled"] as? Bool == true)
        #expect(object["lidClosed"] as? Bool == true)
        #expect(object["internetReachable"] as? Bool == false)
        #expect(object["thermalLevel"] as? String == "serious")
        #expect(object["thermalPressure"] as? Int == 3)
        #expect(object["batteryMaxCelsius"] as? Double == 36.5)
        #expect(object["chipAverageCelsius"] as? Double == 51.25)
        #expect(object["onBattery"] as? Bool == true)
        #expect(object["batteryPercent"] as? Int == 42)
        #expect(object["heatProtection"] as? String == "full")
        #expect(object["lastError"] as? String == "pmset: fictional failure")
        #expect(object["warnings"] as? [String] == [])
        for key in [
            "waitingForFullWake", "daemonRunning", "sleepDisabled", "lidClosed", "internetReachable", "onBattery",
        ] {
            #expect(isJSONBool(object[key]), "\(key) is a JSON boolean")
        }
        #expect(object["waitingForFullWake"] as? Bool == false)
        #expect(object["daemonRunning"] as? Bool == true)

        let stamp = try #require(object["heartbeatAt"] as? String, "heartbeatAt is a string")
        #expect(stamp.hasSuffix("Z") || stamp.hasSuffix("+00:00"), "UTC: \(stamp)")
        let parsed = try #require(parseISO8601(stamp), "ISO 8601: \(stamp)")
        #expect(abs(parsed.timeIntervalSince(heartbeat)) < 0.001)
    }

    @Test("F-002 · E39 · json() has sorted keys, one per indented line")
    func jsonIsSortedAndIndented() {
        let json = StatusView.make(
            snapshot: snapshot(.fresh), intent: .on, liveSleepDisabled: true, now: F002Liveness.fresh.now
        ).json()
        let keys = json.matches(of: /"([A-Za-z]+)"\s*:/).map { String($0.output.1) }
        #expect(keys == allJSONKeys.sorted(), "json:\n\(json)")

        let lines = json.split(separator: "\n")
        for key in allJSONKeys {
            #expect(
                lines.contains {
                    $0.first?.isWhitespace == true && $0.drop(while: \.isWhitespace).hasPrefix("\"\(key)\"")
                },
                "`\(key)` on its own indented line")
        }
    }

    // MARK: - text()

    @Test("F-002 · E40 · text() is the status render plus heat protection and `Daemon: running`")
    func textForRunningDaemon() throws {
        let running = try #require(
            snapshot(.fresh, state: .paused([.noInternet]), sleepDisabled: true, lastError: "pmset: fictional failure"))
        let view = StatusView.make(
            snapshot: running, intent: .on, liveSleepDisabled: false, now: F002Liveness.fresh.now)

        var base = running
        base.sleepDisabled = false
        let expected = try expectedLines(
            rendering: base, heartbeatNever: false, heat: "full", daemon: "running", warnings: [])
        #expect(textLines(view) == expected)
    }

    @Test("F-002 · E41 · text() shows the corrected mode, `Daemon: not running` and a Warning line per warning")
    func textForStoppedDaemon() throws {
        let stale = try #require(
            snapshot(
                .stale, state: .active, temperatures: TemperatureReading(batteryMaxC: 36.5, dieAverageC: nil),
                sleepDisabled: false))
        let view = StatusView.make(snapshot: stale, intent: .on, liveSleepDisabled: true, now: F002Liveness.stale.now)

        var base = stale
        base.state = .off
        base.sleepDisabled = true
        let expected = try expectedLines(
            rendering: base, heartbeatNever: false, heat: "limited", daemon: "not running",
            warnings: [sleepDisabledWarning])
        #expect(textLines(view) == expected)
    }

    @Test("F-002 · E42 · text() without a snapshot shows `Heartbeat: never` and unknown readings")
    func textWithoutSnapshot() throws {
        let view = StatusView.make(snapshot: nil, intent: .off, liveSleepDisabled: nil, now: heartbeat)

        let base = StatusSnapshot(
            state: .off, intent: .off, lidClosed: nil, internetReachable: nil, thermal: nil, temperatures: nil,
            power: nil, sleepDisabled: nil, lastError: nil, heartbeatAt: heartbeat)
        let expected = try expectedLines(
            rendering: base, heartbeatNever: true, heat: "none", daemon: "not running", warnings: [])
        #expect(textLines(view) == expected)
    }
}
