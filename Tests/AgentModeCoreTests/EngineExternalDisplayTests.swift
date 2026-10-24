import Foundation
import Testing

@testable import AgentModeCore

/// Clamshell use with an external display (design A5). Added after the frozen contract; approved with it.
@Suite struct EngineExternalDisplayTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func activeClosedWithMonitor() -> Engine {
        var engine = Engine(config: .default)
        _ = engine.handle(.intent(.on), at: t0)
        _ = engine.handle(.externalDisplay(active: true), at: t0.addingTimeInterval(1))
        _ = engine.handle(.lid(closed: true), at: t0.addingTimeInterval(2))
        return engine
    }

    @Test func pauseWithExternalDisplayDoesNotSleep() {
        var engine = activeClosedWithMonitor()
        let actions = engine.handle(.thermal(ThermalReading(level: .serious, pressure: 0)), at: t0.addingTimeInterval(3))
        #expect(engine.state == .paused([.thermal]))
        #expect(actions.contains(.setSleepDisabled(false)))
        #expect(!actions.contains(.sleepNow))
    }

    @Test func offWithExternalDisplayDoesNotSleep() {
        var engine = activeClosedWithMonitor()
        let actions = engine.handle(.intent(.off), at: t0.addingTimeInterval(3))
        #expect(engine.state == .off)
        #expect(actions.contains(.setSleepDisabled(false)))
        #expect(!actions.contains(.sleepNow))
    }

    @Test func externalDisplayRemovedWithLidClosedTurnsDisplayOff() {
        var engine = activeClosedWithMonitor()
        let actions = engine.handle(.externalDisplay(active: false), at: t0.addingTimeInterval(3))
        #expect(engine.state == .active)
        #expect(actions.contains(.turnDisplayOff))
    }

    @Test func externalDisplayRemovedWithLidOpenDoesNothingToDisplays() {
        var engine = Engine(config: .default)
        _ = engine.handle(.intent(.on), at: t0)
        _ = engine.handle(.externalDisplay(active: true), at: t0.addingTimeInterval(1))
        let actions = engine.handle(.externalDisplay(active: false), at: t0.addingTimeInterval(2))
        #expect(!actions.contains(.turnDisplayOff))
    }
}
