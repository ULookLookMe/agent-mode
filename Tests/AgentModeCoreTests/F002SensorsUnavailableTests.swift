import Foundation
import Testing

@testable import AgentModeCore

// F-002 design §3.5: safe pause when the temperature sensors are unreadable.
// Contract tests written from the spec and the public interfaces only (`Engine.init(config:)`,
// `handle(_:at:)`, `state`, `intent`).

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func at(_ seconds: TimeInterval) -> Date {
    t0.addingTimeInterval(seconds)
}

private func temps(battery: Double?, die: Double?) -> Event {
    .temperatures(TemperatureReading(batteryMaxC: battery, dieAverageC: die))
}

/// Neither the battery nor the chip temperature: an unreadable reading.
private let unreadable = temps(battery: nil, die: nil)

/// Offset from t0 of the first unreadable reading in most scenarios.
private let windowStart: TimeInterval = 60

/// Engine that received `.intent(.on)` at t0 and is ACTIVE.
private func activeEngine(config: AgentModeConfig = .default) throws -> Engine {
    var engine = Engine(config: config)
    _ = engine.handle(.intent(.on), at: t0)
    try #require(engine.state == .active, "precondition: .intent(.on) from OFF activates")
    return engine
}

/// ACTIVE at t0, lid closed at t0+1 s (no external display), unreadable sensors from `windowStart`,
/// paused by them `windowStart + 120 s`.
private func trippedEngine() throws -> Engine {
    var engine = try activeEngine()
    _ = engine.handle(.lid(closed: true), at: at(1))
    _ = engine.handle(unreadable, at: at(windowStart))
    _ = engine.handle(.tick(sleepDisabled: true), at: at(windowStart + 120))
    try #require(
        engine.state == .paused([.sensorsUnavailable]),
        "precondition: 120 s of unreadable sensors with the lid closed pauses")
    return engine
}

@Suite struct F002SensorsUnavailableTests {

    // MARK: - Model, status text and config

    @Test("F-002 · E46 · sensorsUnavailable is the last pause reason")
    func pauseReasonOrder() {
        #expect(PauseReason.allCases == [.noInternet, .thermal, .lowBattery, .sensorsUnavailable])
    }

    @Test("F-002 · E47 · status names the reason `paused (sensors unreadable)`")
    func statusNamesSensorsUnreadable() {
        let snapshot = StatusSnapshot(
            state: .paused([.sensorsUnavailable]), intent: .on, lidClosed: true, internetReachable: true,
            thermal: ThermalReading(level: .nominal, pressure: 0),
            temperatures: TemperatureReading(batteryMaxC: nil, dieAverageC: nil),
            power: PowerReading(onBattery: false, percent: 80), sleepDisabled: false, lastError: nil,
            heartbeatAt: t0)
        #expect(StatusFormatter.render(snapshot).contains("paused (sensors unreadable)"))

        let view = StatusView.make(snapshot: snapshot, intent: .on, liveSleepDisabled: false, now: at(30))
        #expect(view.text().contains("paused (sensors unreadable)"))
    }

    @Test("F-002 · E48 · allowUnknownTemperatures defaults to false")
    func allowUnknownTemperaturesDefaultsToFalse() throws {
        #expect(AgentModeConfig.default.allowUnknownTemperatures == false)
        let built = AgentModeConfig(
            internetTimeoutMinutes: 10, probeIntervalSeconds: 60,
            probeURLs: [try #require(URL(string: "https://example.invalid/probe"))], thermalResumeMinutes: 5,
            batteryFloorPercent: 10, batteryMaxCelsius: 40, dieAverageMaxCelsius: 80, dieSustainMinutes: 5,
            resumeMarginCelsius: 5)
        #expect(built.allowUnknownTemperatures == false)
    }

    @Test(
        "F-002 · E49 · allowUnknownTemperatures is optional in the config JSON",
        arguments: [
            ("{}", false),
            (#"{"allowUnknownTemperatures": null}"#, false),
            (#"{"allowUnknownTemperatures": false}"#, false),
            (#"{"allowUnknownTemperatures": true}"#, true),
            (#"{"batteryFloorPercent": 20, "allowUnknownTemperatures": true}"#, true),
        ]
    )
    func allowUnknownTemperaturesDecodes(json: String, expected: Bool) throws {
        let config = try JSONDecoder().decode(AgentModeConfig.self, from: Data(json.utf8))
        #expect(config.allowUnknownTemperatures == expected)
    }

    // MARK: - Trip

    @Test("F-002 · E50 · with the lid closed, 120 s of unreadable sensors pause with every pause action; 119 s do not")
    func tripsAtHundredTwentySeconds() throws {
        var engine = try activeEngine()
        _ = engine.handle(.lid(closed: true), at: at(1))
        var before = engine.handle(unreadable, at: at(windowStart))
        before += engine.handle(.tick(sleepDisabled: true), at: at(windowStart + 119))
        #expect(engine.state == .active)
        #expect(!before.contains(.setSleepDisabled(false)))

        let actions = engine.handle(.tick(sleepDisabled: true), at: at(windowStart + 120))
        #expect(engine.state == .paused([.sensorsUnavailable]))
        #expect(engine.intent == .on)
        #expect(actions.contains(.notify(.paused([.sensorsUnavailable]))))
        let restore = try #require(actions.firstIndex(of: .setSleepDisabled(false)))
        let sleep = try #require(actions.firstIndex(of: .sleepNow))
        #expect(restore < sleep)
    }

    @Test(
        "F-002 · E51 · any event evaluates the trip, not only ticks",
        arguments: [
            unreadable,
            Event.probe(reachable: true),
            .power(PowerReading(onBattery: false, percent: 80)),
            .thermal(ThermalReading(level: .nominal, pressure: 0)),
        ]
    )
    func anyEventTrips(event: Event) throws {
        var engine = try activeEngine()
        _ = engine.handle(.lid(closed: true), at: at(1))
        _ = engine.handle(unreadable, at: at(windowStart))
        _ = engine.handle(event, at: at(windowStart + 119))
        #expect(engine.state == .active)
        let actions = engine.handle(event, at: at(windowStart + 120))
        #expect(engine.state == .paused([.sensorsUnavailable]))
        #expect(actions.contains(.notify(.paused([.sensorsUnavailable]))))
    }

    @Test("F-002 · E52 · further unreadable readings keep the window's start")
    func repeatedUnreadableKeepsWindowStart() {
        var engine = Engine(config: .default)
        _ = engine.handle(.intent(.on), at: t0)
        _ = engine.handle(.lid(closed: true), at: at(1))
        for offset in stride(from: windowStart, through: windowStart + 90, by: 30) {
            _ = engine.handle(unreadable, at: at(offset))
        }
        _ = engine.handle(.tick(sleepDisabled: true), at: at(windowStart + 119))
        #expect(engine.state == .active)
        _ = engine.handle(.tick(sleepDisabled: true), at: at(windowStart + 120))
        #expect(engine.state == .paused([.sensorsUnavailable]))
    }

    @Test("F-002 · E53 · closing the lid on a window 120 s or older pauses at once and sleeps")
    func lidCloseOnOldWindowTrips() throws {
        var engine = try activeEngine()
        _ = engine.handle(unreadable, at: at(windowStart))
        _ = engine.handle(.tick(sleepDisabled: true), at: at(windowStart + 200))
        try #require(engine.state == .active, "precondition: with the lid state unknown nothing trips")

        let actions = engine.handle(.lid(closed: true), at: at(windowStart + 300))
        #expect(engine.state == .paused([.sensorsUnavailable]))
        #expect(actions.contains(.setSleepDisabled(false)))
        #expect(actions.contains(.sleepNow))
        #expect(actions.contains(.notify(.paused([.sensorsUnavailable]))))
    }

    @Test("F-002 · E54 · the window counts from the first unreadable reading since startup, even before `on`")
    func windowOpenedBeforeOnCounts() {
        var engine = Engine(config: .default)
        _ = engine.handle(unreadable, at: t0)
        _ = engine.handle(.intent(.on), at: at(10))
        _ = engine.handle(.lid(closed: true), at: at(20))
        _ = engine.handle(.tick(sleepDisabled: true), at: at(119))
        #expect(engine.state == .active)
        _ = engine.handle(.tick(sleepDisabled: true), at: at(120))
        #expect(engine.state == .paused([.sensorsUnavailable]))
    }

    // MARK: - Never trips

    @Test("F-002 · E55 · without any temperatures event there is no window")
    func noTemperaturesEventNoWindow() throws {
        var engine = try activeEngine()
        var actions = engine.handle(.lid(closed: true), at: at(1))
        actions += engine.handle(.tick(sleepDisabled: true), at: at(3 * 60))
        actions += engine.handle(.tick(sleepDisabled: true), at: at(9 * 60))
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
    }

    @Test(
        "F-002 · E56 · partial readings (battery only or chip only) never trip",
        arguments: [(35.0, nil), (nil, 50.0)] as [(Double?, Double?)]
    )
    func partialReadingsNeverTrip(battery: Double?, die: Double?) throws {
        var engine = try activeEngine()
        var actions = engine.handle(.lid(closed: true), at: at(1))
        for offset in stride(from: windowStart, through: windowStart + 300, by: 30) {
            actions += engine.handle(temps(battery: battery, die: die), at: at(offset))
        }
        actions += engine.handle(.tick(sleepDisabled: true), at: at(windowStart + 300))
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
    }

    @Test(
        "F-002 · E57 · a reading with any value clears the window and the next unreadable one restarts it",
        arguments: [(35.0, 50.0), (35.0, nil), (nil, 50.0)] as [(Double?, Double?)]
    )
    func readableReadingClearsWindow(battery: Double?, die: Double?) {
        var engine = Engine(config: .default)
        _ = engine.handle(.intent(.on), at: t0)
        _ = engine.handle(.lid(closed: true), at: at(1))
        _ = engine.handle(unreadable, at: at(windowStart))
        _ = engine.handle(temps(battery: battery, die: die), at: at(windowStart + 60))
        let restart = windowStart + 90
        _ = engine.handle(unreadable, at: at(restart))

        _ = engine.handle(.tick(sleepDisabled: true), at: at(windowStart + 120))
        #expect(engine.state == .active, "the first window was cleared")
        _ = engine.handle(.tick(sleepDisabled: true), at: at(restart + 119))
        #expect(engine.state == .active)
        _ = engine.handle(.tick(sleepDisabled: true), at: at(restart + 120))
        #expect(engine.state == .paused([.sensorsUnavailable]))
    }

    @Test(
        "F-002 · E58 · with the lid open or in an unknown state the reason never trips",
        arguments: [nil, false] as [Bool?]
    )
    func lidOpenOrUnknownNeverTrips(lidClosed: Bool?) throws {
        var engine = try activeEngine()
        var actions: [Action] = []
        if let lidClosed {
            actions += engine.handle(.lid(closed: lidClosed), at: at(1))
        }
        actions += engine.handle(unreadable, at: at(windowStart))
        actions += engine.handle(.tick(sleepDisabled: true), at: at(windowStart + 300))
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
    }

    @Test("F-002 · E59 · with an external display the reason never trips")
    func externalDisplayNeverTrips() throws {
        var engine = try activeEngine()
        var actions = engine.handle(.externalDisplay(active: true), at: at(1))
        actions += engine.handle(.lid(closed: true), at: at(2))
        actions += engine.handle(unreadable, at: at(windowStart))
        actions += engine.handle(.tick(sleepDisabled: true), at: at(windowStart + 300))
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
    }

    @Test("F-002 · E60 · with allowUnknownTemperatures the reason never trips")
    func allowUnknownTemperaturesNeverTrips() throws {
        var config = AgentModeConfig.default
        config.allowUnknownTemperatures = true
        var engine = try activeEngine(config: config)
        var actions = engine.handle(.lid(closed: true), at: at(1))
        actions += engine.handle(unreadable, at: at(windowStart))
        actions += engine.handle(.tick(sleepDisabled: true), at: at(windowStart + 300))
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
    }

    // MARK: - Recovery

    @Test(
        "F-002 · E61 · a readable reading with the lid still closed recovers the reason to paused([]), no resume",
        arguments: [(35.0, 50.0), (35.0, nil), (nil, 50.0)] as [(Double?, Double?)]
    )
    func readableReadingRecoversToWaiting(battery: Double?, die: Double?) throws {
        var engine = try trippedEngine()
        var actions = engine.handle(temps(battery: battery, die: die), at: at(windowStart + 150))
        #expect(engine.state == .paused([]))
        actions += engine.handle(.tick(sleepDisabled: false), at: at(windowStart + 300))
        #expect(engine.state == .paused([]))
        #expect(!actions.contains(.setSleepDisabled(true)))
    }

    @Test("F-002 · E62 · opening the lid recovers the reason; resume needs a full wake held 10 s")
    func lidOpenRecoversAndResumesAfterFullWake() throws {
        var engine = try trippedEngine()
        let open = windowStart + 200
        var actions = engine.handle(.lid(closed: false), at: at(open))
        #expect(engine.state == .paused([]))

        actions += engine.handle(.fullWake(true), at: at(open + 10))
        actions += engine.handle(.fullWake(true), at: at(open + 19))
        #expect(engine.state == .paused([]))
        #expect(!actions.contains(.setSleepDisabled(true)))

        let resumed = engine.handle(.fullWake(true), at: at(open + 20))
        #expect(engine.state == .active)
        #expect(resumed.contains(.setSleepDisabled(true)))
        #expect(resumed.contains(.notify(.resumed)))
    }

    @Test("F-002 · E63 · connecting an external display recovers the reason to paused([])")
    func externalDisplayRecovers() throws {
        var engine = try trippedEngine()
        let actions = engine.handle(.externalDisplay(active: true), at: at(windowStart + 200))
        #expect(engine.state == .paused([]))
        #expect(!actions.contains(.setSleepDisabled(true)))
    }
}
