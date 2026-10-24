import Foundation
import Testing

@testable import AgentModeCore

/// Contract for `agentmode status` output (design.md G7, §8.3) and the LaunchAgent plist
/// (design.md §8.1, plan Navigate facts and Tarea R).
@Suite
struct OutputTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func snapshot(
        state: ModeState = .active,
        intent: Intent = .on,
        sleepDisabled: Bool? = true,
        lastError: String? = nil
    ) -> StatusSnapshot {
        StatusSnapshot(
            state: state,
            intent: intent,
            lidClosed: false,
            internetReachable: true,
            thermal: ThermalReading(level: .nominal, pressure: 0),
            temperatures: TemperatureReading(batteryMaxC: 31.0, dieAverageC: 42.0),
            power: PowerReading(onBattery: false, percent: 73),
            sleepDisabled: sleepDisabled,
            lastError: lastError,
            heartbeatAt: t0
        )
    }

    // MARK: - StatusFormatter

    @Test
    func statusShowsModeReasonAndRealSleepDisabled() {
        let text = StatusFormatter.render(
            snapshot(state: .paused([.noInternet]), intent: .on, sleepDisabled: false)
        )
        #expect(text.contains("paused (no internet)"))
        #expect(text.contains("SleepDisabled: 0"))
    }

    @Test
    func statusShowsWaitingForFullWake() {
        let text = StatusFormatter.render(snapshot(state: .paused([]), intent: .on, sleepDisabled: false))
        #expect(text.contains("waiting for full wake"))
    }

    @Test(arguments: [
        (PauseReason.noInternet, "paused (no internet)"),
        (PauseReason.thermal, "paused (heat)"),
        (PauseReason.lowBattery, "paused (low battery)"),
    ])
    func statusNamesEachPauseReason(reason: PauseReason, expected: String) {
        let text = StatusFormatter.render(snapshot(state: .paused([reason]), intent: .on, sleepDisabled: false))
        #expect(text.contains(expected))
    }

    @Test
    func statusListsAllPauseReasons() {
        let text = StatusFormatter.render(
            snapshot(state: .paused([.noInternet, .lowBattery]), intent: .on, sleepDisabled: false)
        )
        #expect(text.contains("paused"))
        #expect(text.contains("no internet"))
        #expect(text.contains("low battery"))
    }

    @Test
    func statusShowsSleepDisabledWhenSet() {
        let text = StatusFormatter.render(snapshot(state: .active, intent: .on, sleepDisabled: true))
        #expect(text.contains("SleepDisabled: 1"))
    }

    @Test
    func statusShowsUnknownForMissingReadings() {
        let empty = StatusSnapshot(
            state: .off,
            intent: .off,
            lidClosed: nil,
            internetReachable: nil,
            thermal: nil,
            temperatures: nil,
            power: nil,
            sleepDisabled: nil,
            lastError: nil,
            heartbeatAt: t0
        )
        let text = StatusFormatter.render(empty)
        #expect(text.contains("SleepDisabled: unknown"))
        #expect(!text.contains("SleepDisabled: 0"))
        #expect(!text.contains("SleepDisabled: 1"))
    }

    @Test
    func statusShowsLastError() {
        let text = StatusFormatter.render(
            snapshot(state: .off, intent: .off, sleepDisabled: false, lastError: "sudo: a password is required")
        )
        #expect(text.contains("sudo: a password is required"))
    }

    // MARK: - LaunchAgentPlist

    @Test
    func plistHasRequiredKeys() throws {
        let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
        let raw = LaunchAgentPlist.make(home: home)

        // Round-trip through the property list encoder: launchd needs a valid plist.
        let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(LaunchAgentPlist.label == "com.jsanchez.agentmode")
        #expect(plist["Label"] as? String == "com.jsanchez.agentmode")
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/tester/.local/bin/agentmode", "daemon"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["ExitTimeOut"] as? Int == 10)
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")

        let stdout = try #require(plist["StandardOutPath"] as? String)
        let stderr = try #require(plist["StandardErrorPath"] as? String)
        #expect(stdout.hasPrefix("/Users/tester/Library/Logs/"))
        #expect(stderr.hasPrefix("/Users/tester/Library/Logs/"))
    }
}
