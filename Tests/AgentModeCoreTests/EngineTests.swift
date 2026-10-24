import Foundation
import Testing

@testable import AgentModeCore

// Contract tests for the agent-mode state machine (F-001, design.md §4, §8.2, §8.3, §8.4).
// Written from the spec and the Tarea 0 interfaces only.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let minute: TimeInterval = 60

private func at(_ seconds: TimeInterval) -> Date {
    t0.addingTimeInterval(seconds)
}

private func isNotify(_ action: Action) -> Bool {
    if case .notify = action { return true }
    return false
}

private func isLog(_ action: Action) -> Bool {
    if case .log = action { return true }
    return false
}

private func isErrorNotice(_ action: Action) -> Bool {
    if case .notify(.error(_)) = action { return true }
    return false
}

private func temps(battery: Double?, die: Double?) -> Event {
    .temperatures(TemperatureReading(batteryMaxC: battery, dieAverageC: die))
}

private func power(onBattery: Bool, percent: Int?) -> Event {
    .power(PowerReading(onBattery: onBattery, percent: percent))
}

private func thermal(_ level: ThermalLevel, _ pressure: UInt64) -> Event {
    .thermal(ThermalReading(level: level, pressure: pressure))
}

/// Engine that received `.intent(.on)` at `time` and is ACTIVE.
private func activeEngine(at time: Date = t0) throws -> Engine {
    var engine = Engine(config: .default)
    _ = engine.handle(.intent(.on), at: time)
    try #require(engine.state == .active, "precondition: .intent(.on) from OFF activates")
    return engine
}

/// Engine activated at t0 and paused by low battery (5 % on battery) at t0+1m.
private func pausedByLowBattery() throws -> Engine {
    var engine = try activeEngine()
    _ = engine.handle(power(onBattery: true, percent: 5), at: at(1 * minute))
    try #require(engine.state == .paused([.lowBattery]), "precondition: 5 % on battery pauses")
    return engine
}

/// "Ready to resume": `.fullWake(true)` at `time` and again at `time + 10 s`.
@discardableResult
private func readyToResume(_ engine: inout Engine, at time: Date) -> [Action] {
    var actions = engine.handle(.fullWake(true), at: time)
    actions += engine.handle(.fullWake(true), at: time.addingTimeInterval(10))
    return actions
}

/// Sends `event` every `step` seconds from `start` through `end` (inclusive, offsets from t0).
@discardableResult
private func repeatEvent(
    _ event: Event,
    _ engine: inout Engine,
    from start: TimeInterval,
    through end: TimeInterval,
    every step: TimeInterval
) -> [Action] {
    var actions: [Action] = []
    for offset in stride(from: start, through: end, by: step) {
        actions += engine.handle(event, at: at(offset))
    }
    return actions
}

@Suite struct EngineTests {
    enum Setup: String, CaseIterable, Sendable {
        case neverOn, turnedOff, active, paused
    }

    static func makeEngine(_ setup: Setup) throws -> Engine {
        switch setup {
        case .neverOn:
            return Engine(config: .default)
        case .turnedOff:
            var engine = try activeEngine()
            _ = engine.handle(.intent(.off), at: at(1 * minute))
            try #require(engine.state == .off, "precondition: .intent(.off) turns the mode off")
            return engine
        case .active:
            return try activeEngine()
        case .paused:
            return try pausedByLowBattery()
        }
    }

    // MARK: - on / off / lid

    @Test func onFromOffActivates() {
        var engine = Engine(config: .default)
        let actions = engine.handle(.intent(.on), at: t0)
        #expect(engine.state == .active)
        #expect(engine.intent == .on)
        #expect(actions.contains(.setSleepDisabled(true)))
        #expect(actions.contains(.notify(.activated)))
    }

    @Test func repeatedOnIsIdempotent() throws {
        var engine = try activeEngine()
        let actions = engine.handle(.intent(.on), at: at(1))
        #expect(actions == [])
        #expect(engine.state == .active)
    }

    @Test func offFromActiveRestoresSleep() throws {
        var engine = try activeEngine()
        _ = engine.handle(.lid(closed: false), at: at(1))
        let actions = engine.handle(.intent(.off), at: at(2))
        #expect(engine.state == .off)
        #expect(engine.intent == .off)
        // Exact effects from the row; `.log` entries are left to the builder (design §10) and,
        // per Tarea 2, may only follow `notify`.
        let effects = actions.filter { !isLog($0) }
        #expect(effects == [.setSleepDisabled(false), .notify(.deactivated)])
        #expect(Array(actions.prefix(effects.count)) == effects, "log entries, if any, come last")
        #expect(!actions.contains(.sleepNow))
    }

    @Test func offWithLidClosedSleepsNow() throws {
        var engine = try activeEngine()
        _ = engine.handle(.lid(closed: true), at: at(1))
        let actions = engine.handle(.intent(.off), at: at(2))
        #expect(engine.state == .off)
        let restore = try #require(actions.firstIndex(of: .setSleepDisabled(false)))
        let sleep = try #require(actions.firstIndex(of: .sleepNow))
        #expect(restore < sleep)
    }

    @Test func lidCloseWhileActiveTurnsDisplayOff() throws {
        // Default case: the engine has never been told about an external display.
        var engine = try activeEngine()
        let actions = engine.handle(.lid(closed: true), at: at(1))
        #expect(actions.contains(.turnDisplayOff))
        #expect(engine.state == .active)
    }

    @Test func lidCloseWithExternalDisplayKeepsDisplays() throws {
        var engine = try activeEngine()
        _ = engine.handle(.externalDisplay(active: true), at: at(1))
        let actions = engine.handle(.lid(closed: true), at: at(2))
        #expect(!actions.contains(.turnDisplayOff))
        #expect(engine.state == .active)
    }

    @Test func lidCloseWhileOffDoesNothing() {
        var neverOn = Engine(config: .default)
        let neverOnActions = neverOn.handle(.lid(closed: true), at: t0)
        #expect(neverOnActions == [])
        #expect(neverOn.state == .off)

        var turnedOff = Engine(config: .default)
        _ = turnedOff.handle(.intent(.on), at: t0)
        _ = turnedOff.handle(.intent(.off), at: at(1))
        let turnedOffActions = turnedOff.handle(.lid(closed: true), at: at(2))
        #expect(turnedOffActions == [])
        #expect(turnedOff.state == .off)
    }

    // MARK: - P1 internet

    @Test func internetLossUnderTimeoutKeepsActive() throws {
        var engine = try activeEngine()
        var actions = repeatEvent(
            .probe(reachable: false), &engine, from: 0, through: 9 * minute, every: minute)
        actions += engine.handle(.probe(reachable: false), at: at(9 * minute + 59))
        actions += engine.handle(.tick(sleepDisabled: true), at: at(9 * minute + 59))
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
    }

    @Test func internetLossAtTimeoutPauses() throws {
        var engine = try activeEngine()
        repeatEvent(.probe(reachable: false), &engine, from: 0, through: 9 * minute, every: minute)
        _ = engine.handle(.probe(reachable: false), at: at(9 * minute + 59))
        let actions = engine.handle(.tick(sleepDisabled: true), at: at(10 * minute))
        #expect(engine.state == .paused([.noInternet]))
        #expect(actions.contains(.setSleepDisabled(false)))
        #expect(actions.contains(.notify(.paused([.noInternet]))))
    }

    @Test func successResetsInternetTimer() throws {
        var engine = try activeEngine()
        var actions = repeatEvent(
            .probe(reachable: false), &engine, from: 0, through: 7 * minute, every: minute)
        actions += engine.handle(.probe(reachable: true), at: at(8 * minute))
        actions += repeatEvent(
            .probe(reachable: false), &engine, from: 9 * minute, through: 17 * minute, every: minute)
        actions += engine.handle(.tick(sleepDisabled: true), at: at(17 * minute))
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
    }

    @Test func internetTimerStartsAtOn() throws {
        var engine = Engine(config: .default)
        _ = engine.handle(.probe(reachable: false), at: t0)
        _ = engine.handle(.intent(.on), at: at(5 * minute))
        try #require(engine.state == .active, "precondition: .intent(.on) activates")
        repeatEvent(
            .probe(reachable: false), &engine, from: 5 * minute, through: 14 * minute, every: minute)
        #expect(engine.state == .active)
        _ = engine.handle(.tick(sleepDisabled: true), at: at(15 * minute))
        #expect(engine.state == .paused([.noInternet]))
    }

    // MARK: - P2 heat (macOS thermal state and pressure)

    @Test(arguments: [
        ThermalReading(level: .serious, pressure: 0),
        ThermalReading(level: .critical, pressure: 0),
        ThermalReading(level: .nominal, pressure: 2),
        ThermalReading(level: .nominal, pressure: 3),
        ThermalReading(level: .nominal, pressure: 4),
    ])
    func thermalTripPausesImmediately(reading: ThermalReading) throws {
        var engine = try activeEngine()
        let actions = engine.handle(.thermal(reading), at: at(1 * minute))
        #expect(engine.state == .paused([.thermal]))
        #expect(actions.contains(.setSleepDisabled(false)))
    }

    @Test(arguments: [
        ThermalReading(level: .fair, pressure: 0),
        ThermalReading(level: .nominal, pressure: 1),
    ])
    func thermalBelowTripKeepsActive(reading: ThermalReading) throws {
        var engine = try activeEngine()
        var actions = engine.handle(.thermal(reading), at: at(1 * minute))
        #expect(engine.state == .active)
        actions += engine.handle(.tick(sleepDisabled: true), at: at(7 * minute))
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
    }

    @Test func thermalResumeNeedsCalmMinutes() throws {
        var engine = try activeEngine()
        _ = engine.handle(temps(battery: 30, die: 45), at: at(30))
        _ = engine.handle(thermal(.serious, 0), at: at(1 * minute))
        try #require(engine.state == .paused([.thermal]), "precondition: serious thermal state pauses")

        let t = 2 * minute
        _ = engine.handle(thermal(.nominal, 0), at: at(t))
        readyToResume(&engine, at: at(t))
        _ = engine.handle(.tick(sleepDisabled: false), at: at(t + 4 * minute + 59))
        #expect(engine.state == .paused([.thermal]))

        let actions = engine.handle(.tick(sleepDisabled: false), at: at(t + 5 * minute))
        #expect(engine.state == .active)
        #expect(actions.contains(.notify(.resumed)))
        #expect(actions.contains(.setSleepDisabled(true)))
    }

    // MARK: - P2 heat (real temperature sensors)

    @Test(arguments: [(40.0, true), (39.9, false)])
    func batteryHotPausesImmediately(batteryCelsius: Double, pauses: Bool) throws {
        var engine = try activeEngine()
        let actions = engine.handle(temps(battery: batteryCelsius, die: 45), at: at(1 * minute))
        if pauses {
            #expect(engine.state == .paused([.thermal]))
            #expect(actions.contains(.setSleepDisabled(false)))
        } else {
            #expect(engine.state == .active)
            #expect(!actions.contains(.setSleepDisabled(false)))
        }
    }

    @Test func dieHotPausesAfterSustainMinutes() throws {
        var engine = try activeEngine()
        let t = 1 * minute
        repeatEvent(
            temps(battery: 30, die: 80.0), &engine, from: t, through: t + 4 * minute + 30, every: 30)
        _ = engine.handle(.tick(sleepDisabled: true), at: at(t + 4 * minute + 59))
        #expect(engine.state == .active)

        let actions = engine.handle(.tick(sleepDisabled: true), at: at(t + 5 * minute))
        #expect(engine.state == .paused([.thermal]))
        #expect(actions.contains(.setSleepDisabled(false)))
    }

    @Test func dieDipResetsSustainTimer() throws {
        var engine = try activeEngine()
        let t = 1 * minute
        let hot = temps(battery: 30, die: 80.0)
        repeatEvent(hot, &engine, from: t, through: t + 4 * minute, every: 30)
        _ = engine.handle(temps(battery: 30, die: 79.9), at: at(t + 4 * minute + 30))
        repeatEvent(hot, &engine, from: t + 5 * minute, through: t + 9 * minute, every: 30)
        _ = engine.handle(.tick(sleepDisabled: true), at: at(t + 9 * minute))
        #expect(engine.state == .active)

        repeatEvent(hot, &engine, from: t + 9 * minute + 30, through: t + 10 * minute, every: 30)
        _ = engine.handle(.tick(sleepDisabled: true), at: at(t + 10 * minute))
        #expect(engine.state == .paused([.thermal]))
    }

    @Test func temperatureResumeNeedsMargin() throws {
        var engine = try activeEngine()
        _ = engine.handle(thermal(.nominal, 0), at: at(10))
        _ = engine.handle(temps(battery: 40.0, die: 45), at: at(1 * minute))
        try #require(engine.state == .paused([.thermal]), "precondition: battery at 40 °C pauses")

        // 6 min at 36 °C (below the trip, above trip - margin = 35 °C) while fully awake.
        let a = 2 * minute
        var actions = engine.handle(temps(battery: 36.0, die: 45), at: at(a))
        actions += readyToResume(&engine, at: at(a))
        for offset in stride(from: a + 30, through: a + 6 * minute, by: 30) {
            actions += engine.handle(temps(battery: 36.0, die: 45), at: at(offset))
            actions += engine.handle(.tick(sleepDisabled: false), at: at(offset))
        }
        #expect(engine.state == .paused([.thermal]))
        #expect(!actions.contains(.setSleepDisabled(true)))

        // Below the margin from t: resumes after thermalResumeMinutes.
        let t = a + 6 * minute + 30
        repeatEvent(temps(battery: 34.9, die: 45), &engine, from: t, through: t + 4 * minute + 30, every: 30)
        _ = engine.handle(.tick(sleepDisabled: false), at: at(t + 5 * minute))
        #expect(engine.state == .active)
    }

    @Test func unknownTemperaturesDoNotPause() throws {
        var engine = try activeEngine()
        let unknown = temps(battery: nil, die: nil)
        var actions = engine.handle(unknown, at: at(1 * minute))
        #expect(engine.state == .active)
        actions += repeatEvent(unknown, &engine, from: 1 * minute + 30, through: 7 * minute, every: 30)
        actions += engine.handle(.tick(sleepDisabled: true), at: at(7 * minute))
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
    }

    // MARK: - P3 battery

    @Test(arguments: [(10, true), (11, false)])
    func lowBatteryPausesAtFloor(percent: Int, pauses: Bool) throws {
        var engine = try activeEngine()
        let actions = engine.handle(power(onBattery: true, percent: percent), at: at(1 * minute))
        if pauses {
            #expect(engine.state == .paused([.lowBattery]))
            #expect(actions.contains(.setSleepDisabled(false)))
        } else {
            #expect(engine.state == .active)
            #expect(!actions.contains(.setSleepDisabled(false)))
        }
    }

    @Test func lowBatteryIgnoredOnCharger() throws {
        var engine = try activeEngine()
        let actions = engine.handle(power(onBattery: false, percent: 5), at: at(1 * minute))
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
    }

    @Test func unknownPowerDoesNotPause() throws {
        var engine = try activeEngine()
        let actions = engine.handle(power(onBattery: true, percent: nil), at: at(1 * minute))
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
    }

    @Test func chargerResumesLowBattery() throws {
        var engine = try activeEngine()
        _ = engine.handle(power(onBattery: true, percent: 8), at: at(1 * minute))
        try #require(engine.state == .paused([.lowBattery]), "precondition: 8 % on battery pauses")

        var actions = engine.handle(power(onBattery: false, percent: 8), at: at(2 * minute))
        actions += readyToResume(&engine, at: at(2 * minute))
        #expect(engine.state == .active)
        #expect(actions.contains(.setSleepDisabled(true)))
        #expect(actions.contains(.notify(.resumed)))
    }

    // MARK: - Resume (G6, A6)

    @Test func noResumeDuringDarkWake() throws {
        var engine = try activeEngine()
        _ = engine.handle(.probe(reachable: false), at: t0)
        _ = engine.handle(.lid(closed: true), at: at(30))
        repeatEvent(.probe(reachable: false), &engine, from: 1 * minute, through: 10 * minute, every: minute)
        _ = engine.handle(.tick(sleepDisabled: true), at: at(10 * minute))
        try #require(engine.state == .paused([.noInternet]), "precondition: 10 min offline pauses")

        let wake = 15 * minute
        var actions = engine.handle(.fullWake(false), at: at(wake))
        actions += engine.handle(.probe(reachable: true), at: at(wake + 5))
        actions += engine.handle(.fullWake(false), at: at(wake + 10))
        actions += engine.handle(.tick(sleepDisabled: false), at: at(wake + 30))
        #expect(engine.state == .paused([]))
        #expect(!actions.contains(.setSleepDisabled(true)))
    }

    @Test func resumeNeedsTenSecondsOfFullWake() throws {
        var engine = try pausedByLowBattery()
        _ = engine.handle(power(onBattery: false, percent: 5), at: at(2 * minute))

        let t = 3 * minute
        _ = engine.handle(.fullWake(true), at: at(t))
        #expect(engine.state == .paused([]))
        _ = engine.handle(.fullWake(true), at: at(t + 9))
        #expect(engine.state == .paused([]))
        let actions = engine.handle(.fullWake(true), at: at(t + 10))
        #expect(engine.state == .active)
        #expect(actions.contains(.setSleepDisabled(true)))
    }

    @Test func resumeWaitsForAllReasons() throws {
        var engine = try activeEngine()
        repeatEvent(.probe(reachable: false), &engine, from: 0, through: 9 * minute, every: minute)
        _ = engine.handle(.tick(sleepDisabled: true), at: at(10 * minute))
        try #require(engine.state == .paused([.noInternet]), "precondition: 10 min offline pauses")
        _ = engine.handle(power(onBattery: true, percent: 5), at: at(10 * minute + 30))
        try #require(
            engine.state == .paused([.noInternet, .lowBattery]),
            "precondition: low battery while paused is recorded as a second reason")

        var actions = engine.handle(.probe(reachable: true), at: at(11 * minute))
        actions += readyToResume(&engine, at: at(11 * minute))
        #expect(engine.state == .paused([.lowBattery]))
        #expect(!actions.contains(.setSleepDisabled(true)))
    }

    @Test func manualOffIsFinal() throws {
        var engine = try pausedByLowBattery()
        _ = engine.handle(.intent(.off), at: at(2 * minute))
        try #require(engine.state == .off, "precondition: .intent(.off) from PAUSED turns the mode off")

        var actions = engine.handle(.probe(reachable: true), at: at(3 * minute))
        actions += engine.handle(power(onBattery: false, percent: 50), at: at(3 * minute + 1))
        actions += readyToResume(&engine, at: at(3 * minute + 2))
        actions += engine.handle(.tick(sleepDisabled: false), at: at(4 * minute))
        #expect(engine.state == .off)
        #expect(engine.intent == .off)
        #expect(!actions.contains(.setSleepDisabled(true)))
    }

    @Test(arguments: [
        (thermal(.serious, 0), PauseReason.thermal),
        (temps(battery: 41, die: 45), PauseReason.thermal),
        (power(onBattery: true, percent: 10), PauseReason.lowBattery),
    ])
    func onWhileTrippedStartsPaused(reading: Event, reason: PauseReason) {
        var engine = Engine(config: .default)
        _ = engine.handle(reading, at: t0)
        let actions = engine.handle(.intent(.on), at: at(1 * minute))
        #expect(engine.state == .paused([reason]))
        #expect(engine.intent == .on)
        #expect(!actions.contains(.setSleepDisabled(true)))
    }

    @Test func pauseWithLidClosedSleepsNow() throws {
        var engine = try activeEngine()
        _ = engine.handle(.lid(closed: true), at: at(30))
        let actions = engine.handle(temps(battery: 42, die: 50), at: at(1 * minute))
        #expect(engine.state == .paused([.thermal]))
        let restore = try #require(actions.firstIndex(of: .setSleepDisabled(false)))
        let sleep = try #require(actions.firstIndex(of: .sleepNow))
        #expect(restore < sleep)
    }

    // MARK: - Self-heal, startup, termination, apply failure (A1)

    @Test func selfHealReappliesWhenActive() throws {
        var engine = try activeEngine()
        let actions = engine.handle(.tick(sleepDisabled: false), at: at(1 * minute))
        #expect(actions.contains(.setSleepDisabled(true)))
        #expect(engine.state == .active)
    }

    @Test(arguments: [Setup.neverOn, .turnedOff, .paused])
    func selfHealClearsWhenNotActive(setup: Setup) throws {
        var engine = try Self.makeEngine(setup)
        let actions = engine.handle(.tick(sleepDisabled: true), at: at(5 * minute))
        #expect(actions.contains(.setSleepDisabled(false)))
        #expect(engine.state != .active)
    }

    @Test(arguments: [(Intent.on, false), (Intent.off, true)])
    func startupReconcilesFromIntent(intent: Intent, sleepDisabled: Bool) {
        var engine = Engine(config: .default)
        let actions = engine.handle(.startup(intent: intent, sleepDisabled: sleepDisabled), at: t0)
        switch intent {
        case .on:
            #expect(engine.state == .active)
            #expect(engine.intent == .on)
            #expect(actions.contains(.setSleepDisabled(true)))
        case .off:
            #expect(engine.state == .off)
            #expect(engine.intent == .off)
            #expect(actions.contains(.setSleepDisabled(false)))
        }
        #expect(!actions.contains(where: isNotify))
    }

    @Test(arguments: [Setup.active, .paused, .neverOn, .turnedOff])
    func terminatingRestoresSleep(setup: Setup) throws {
        var engine = try Self.makeEngine(setup)
        let actions = engine.handle(.terminating, at: at(5 * minute))
        #expect(actions.contains(.setSleepDisabled(false)))
    }

    @Test func applyFailureFallsBackToOffWithError() {
        var engine = Engine(config: .default)
        _ = engine.handle(.intent(.on), at: t0)
        let message = "sudo: a password is required"
        let actions = engine.handle(.applyFailed(message), at: at(5))
        #expect(engine.state == .off)
        #expect(engine.intent == .off)
        #expect(engine.lastError?.contains(message) == true)
        #expect(actions.contains(where: isErrorNotice))
    }
}
