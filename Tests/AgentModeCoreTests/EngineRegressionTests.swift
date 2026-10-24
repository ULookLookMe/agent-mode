import Foundation
import Testing

@testable import AgentModeCore

/// Regression tests for defects found in review (F-001, design §8.2, §8.3, A1, A5, A6). Added after the
/// frozen contract; approved with it.
@Suite struct EngineRegressionTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let minute: TimeInterval = 60

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func onBattery(_ percent: Int) -> Event {
        .power(PowerReading(onBattery: true, percent: percent))
    }

    private var charger: Event {
        .power(PowerReading(onBattery: false, percent: 12))
    }

    // MARK: - Restart of the daemon (A6, design §8.3)

    /// launchd restarts the daemon during a DarkWake with the lid closed: it must not set
    /// `disablesleep 1` inside the bag, and it resumes only through a full wake.
    @Test func restartWithLidClosedWaitsForFullWake() {
        var engine = Engine(config: .default)
        _ = engine.handle(.externalDisplay(active: false), at: t0)
        _ = engine.handle(.lid(closed: true), at: t0)
        _ = engine.handle(.fullWake(false), at: t0)
        var actions = engine.handle(.startup(intent: .on, sleepDisabled: false), at: t0)
        #expect(engine.state == .paused([]))
        #expect(engine.intent == .on)

        actions += engine.handle(charger, at: at(1))
        for offset in stride(from: minute, through: 30 * minute, by: minute) {
            actions += engine.handle(.fullWake(false), at: at(offset))
            actions += engine.handle(.tick(sleepDisabled: false), at: at(offset))
        }
        #expect(engine.state == .paused([]))
        #expect(!actions.contains(.setSleepDisabled(true)))

        _ = engine.handle(.lid(closed: false), at: at(31 * minute))
        var resume = engine.handle(.fullWake(true), at: at(31 * minute))
        resume += engine.handle(.fullWake(true), at: at(31 * minute + 10))
        #expect(engine.state == .active)
        #expect(resume.contains(.setSleepDisabled(true)))
        #expect(resume.contains(.notify(.resumed)))
    }

    /// A crash while ACTIVE leaves `SleepDisabled` at 1, so the Mac never slept and this is not a DarkWake:
    /// the restarted daemon carries on (design §8.3, "se reaplica según el estado guardado").
    @Test func restartWhileStillAwakeKeepsActive() {
        var engine = Engine(config: .default)
        _ = engine.handle(.externalDisplay(active: false), at: t0)
        _ = engine.handle(.lid(closed: true), at: t0)
        _ = engine.handle(.fullWake(false), at: t0)
        let actions = engine.handle(.startup(intent: .on, sleepDisabled: true), at: t0)
        #expect(engine.state == .active)
        #expect(!actions.contains(.setSleepDisabled(false)))
        #expect(!actions.contains(.sleepNow))
    }

    /// A restart with the mode off and `SleepDisabled` stuck at 1 behind a closed lid restores sleep and
    /// puts the Mac to sleep, because clearing `disablesleep` with the lid closed does not (design §8.3).
    @Test func restartOffWithLidClosedSleepsNow() throws {
        var engine = Engine(config: .default)
        _ = engine.handle(.externalDisplay(active: false), at: t0)
        _ = engine.handle(.lid(closed: true), at: t0)
        let actions = engine.handle(.startup(intent: .off, sleepDisabled: true), at: t0)
        #expect(engine.state == .off)
        let restore = try #require(actions.firstIndex(of: .setSleepDisabled(false)))
        let sleep = try #require(actions.firstIndex(of: .sleepNow))
        #expect(restore < sleep)
    }

    /// A restart keeps the pause the previous daemon saved, so its recovery rules still apply: 37 °C is
    /// under the 40 °C trip but over the 35 °C calm threshold, so a heat pause holds (design §8.2, §8.3).
    @Test func restartKeepsSavedPauseReasons() {
        var engine = Engine(config: .default)
        _ = engine.handle(.savedState(.paused([.thermal])), at: t0)
        _ = engine.handle(.lid(closed: false), at: t0)
        _ = engine.handle(.fullWake(true), at: t0)
        var actions = engine.handle(.startup(intent: .on, sleepDisabled: false), at: t0)
        #expect(engine.state == .paused([.thermal]))

        for offset in stride(from: 0, through: 10 * minute, by: 30) {
            actions += engine.handle(.temperatures(TemperatureReading(batteryMaxC: 37, dieAverageC: 50)), at: at(offset))
            actions += engine.handle(.fullWake(true), at: at(offset))
        }
        actions += engine.handle(.tick(sleepDisabled: false), at: at(10 * minute))
        #expect(engine.state == .paused([.thermal]))
        #expect(!actions.contains(.setSleepDisabled(true)))

        _ = engine.handle(.temperatures(TemperatureReading(batteryMaxC: 34, dieAverageC: 50)), at: at(10 * minute + 30))
        let resume = engine.handle(.tick(sleepDisabled: false), at: at(15 * minute + 30))
        #expect(engine.state == .active)
        #expect(resume.contains(.setSleepDisabled(true)))
    }

    /// A saved pause means nothing once the user turned the mode off.
    @Test func savedPauseIsIgnoredWhenIntentIsOff() {
        var engine = Engine(config: .default)
        _ = engine.handle(.savedState(.paused([.lowBattery])), at: t0)
        _ = engine.handle(.startup(intent: .off, sleepDisabled: false), at: t0)
        #expect(engine.state == .off)
    }

    // MARK: - Self-heal after a failed restore (A1, A2)

    /// A pause with the lid closed whose `disablesleep 0` failed leaves the Mac awake in the bag. Once the
    /// self-heal clears `SleepDisabled`, the Mac must also be put to sleep.
    @Test func selfHealAfterFailedRestoreSleepsNow() throws {
        var engine = Engine(config: .default)
        _ = engine.handle(.intent(.on), at: t0)
        _ = engine.handle(.lid(closed: true), at: at(30))
        let pause = engine.handle(onBattery(10), at: at(1 * minute))
        try #require(pause.contains(.sleepNow), "precondition: a pause with the lid closed sleeps")
        _ = engine.handle(.applyFailed("sudo: a password is required"), at: at(1 * minute + 1))
        try #require(engine.state == .off, "precondition: a failed apply leaves the mode off")

        let actions = engine.handle(.tick(sleepDisabled: true), at: at(2 * minute))
        let restore = try #require(actions.firstIndex(of: .setSleepDisabled(false)))
        let sleep = try #require(actions.firstIndex(of: .sleepNow))
        #expect(restore < sleep)
    }

    /// With an external display in use the Mac is in use in clamshell mode, so the self-heal never sleeps it (A5).
    @Test func selfHealWithExternalDisplayDoesNotSleep() {
        var engine = Engine(config: .default)
        _ = engine.handle(.intent(.on), at: t0)
        _ = engine.handle(.externalDisplay(active: true), at: at(1))
        _ = engine.handle(.lid(closed: true), at: at(2))
        _ = engine.handle(.intent(.off), at: at(3))
        let actions = engine.handle(.tick(sleepDisabled: true), at: at(1 * minute))
        #expect(actions.contains(.setSleepDisabled(false)))
        #expect(!actions.contains(.sleepNow))
    }

    /// With the lid open the Mac sleeps by itself once `disablesleep` is cleared.
    @Test func selfHealWithLidOpenDoesNotSleep() {
        var engine = Engine(config: .default)
        _ = engine.handle(.lid(closed: false), at: t0)
        let actions = engine.handle(.tick(sleepDisabled: true), at: at(1 * minute))
        #expect(actions.contains(.setSleepDisabled(false)))
        #expect(!actions.contains(.sleepNow))
    }
}
