import Foundation
import Testing

@testable import AgentModeCore

/// Contract for `Predicates` (design §8.4, §G5/G6; plan Tarea 0 and Tarea R).
@Suite struct PredicatesTests {
    // P2 trips on macOS thermal state serious/critical or thermal pressure heavy (2) or higher.
    static let tripTable: [(ThermalLevel, UInt64, Bool)] = [
        (.serious, 0, true),
        (.critical, 0, true),
        (.nominal, 2, true),
        (.nominal, 3, true),
        (.nominal, 4, true),
        (.fair, 0, false),
        (.nominal, 1, false),
    ]

    // Resume needs macOS thermal state nominal/fair and pressure below heavy (2).
    static let calmTable: [(ThermalLevel, UInt64, Bool)] = [
        (.nominal, 0, true),
        (.fair, 0, true),
        (.nominal, 1, true),
        (.fair, 1, true),
        (.serious, 0, false),
        (.critical, 0, false),
        (.nominal, 2, false),
        (.nominal, 3, false),
        (.fair, 3, false),
        (.nominal, 4, false),
    ]

    @Test(arguments: tripTable)
    func thermalTripPredicate(level: ThermalLevel, pressure: UInt64, expected: Bool) {
        let reading = ThermalReading(level: level, pressure: pressure)
        #expect(Predicates.isThermalTrip(reading) == expected)
    }

    @Test(arguments: calmTable)
    func thermalCalmPredicate(level: ThermalLevel, pressure: UInt64, expected: Bool) {
        let reading = ThermalReading(level: level, pressure: pressure)
        #expect(Predicates.isThermalCalm(reading) == expected)
    }

    @Test(arguments: [
        (57, 100, 57 as Int?),
        (3, 4, 75 as Int?),
        (5, 0, nil as Int?),
        (5, -1, nil as Int?),
    ])
    func batteryPercentPredicate(current: Int, max: Int, expected: Int?) {
        #expect(Predicates.batteryPercent(current: current, max: max) == expected)
    }

    // Full wake = Graphics capability bit (0x02) and (lid open or external display active).
    // An unreadable capability value is never a full wake (A6), with the lid open or closed (design §8.4).
    static let fullWakeTable: [(UInt32?, Bool, Bool, Bool)] = [
        (0x0F, false, false, true),  // lid open
        (0x0F, true, false, false),  // lid closed, no external display
        (0x0F, true, true, true),  // lid closed, external display active
        (0x0D, true, false, false),  // no Graphics bit, lid closed
        (0x0D, true, true, false),  // no Graphics bit, even with external display
        (nil, true, false, false),  // unreadable capabilities, lid closed
        (nil, true, true, false),  // unreadable capabilities, even with external display
        (0x02, false, false, true),  // Graphics bit alone is enough with lid open
        (0x0D, false, false, false),  // no Graphics bit with the lid open: dark wake on a desk
        (nil, false, false, false),  // unreadable capabilities with the lid open
    ]

    @Test(arguments: fullWakeTable)
    func fullWakePredicate(capabilities: UInt32?, lidClosed: Bool, externalDisplayActive: Bool, expected: Bool) {
        let result = Predicates.isFullWake(
            capabilities: capabilities, lidClosed: lidClosed, externalDisplayActive: externalDisplayActive)
        #expect(result == expected)
    }

    @Test func temperatureSummaryFromRealSensors() throws {
        let samples = [
            SensorSample(name: "PMU tdie1", celsius: 34.93),
            SensorSample(name: "PMU tdie2", celsius: 35.41),
            SensorSample(name: "PMU2 tdie1", celsius: 34.69),
            SensorSample(name: "PMU tdev1", celsius: -9202.93),
            SensorSample(name: "gas gauge battery", celsius: 31.0),
            SensorSample(name: "gas gauge battery", celsius: 31.7),
            SensorSample(name: "NAND CH0 temp", celsius: 34.0),
        ]

        let summary = Predicates.temperatureSummary(samples)

        let battery = try #require(summary.batteryMaxC)
        #expect(battery == 31.7)
        let die = try #require(summary.dieAverageC)
        #expect(abs(die - 35.01) <= 0.01)
    }

    @Test func temperatureSummaryWithoutValidSensorsIsUnknown() {
        let summary = Predicates.temperatureSummary([SensorSample(name: "PMU tdev1", celsius: -9202.93)])

        #expect(summary.batteryMaxC == nil)
        #expect(summary.dieAverageC == nil)
    }

    // Edge of the same rule: the valid range [-20, 150] is inclusive, and "battery" matches without case.
    @Test func temperatureSummaryRangeIsInclusiveAndBatteryMatchIgnoresCase() throws {
        let samples = [
            SensorSample(name: "Main BATTERY Cell", celsius: 150.0),
            SensorSample(name: "gas gauge battery", celsius: -20.0),
            SensorSample(name: "gas gauge battery", celsius: 150.1),
            SensorSample(name: "PMU tdie1", celsius: 40.0),
            SensorSample(name: "PMU tdie2", celsius: -20.1),
            SensorSample(name: "PMU tdie3", celsius: 150.5),
        ]

        let summary = Predicates.temperatureSummary(samples)

        let battery = try #require(summary.batteryMaxC)
        #expect(battery == 150.0)
        let die = try #require(summary.dieAverageC)
        #expect(abs(die - 40.0) <= 0.01)
    }
}
