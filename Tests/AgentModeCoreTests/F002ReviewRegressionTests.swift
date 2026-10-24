import Foundation
import Testing

@testable import AgentModeCore

// F-002 regression tests for bugs found by the clean-context review (2026-10-18), written before the fixes.

private let heartbeat = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func runningSnapshot(temperatures: TemperatureReading?, lastError: String? = nil) -> StatusSnapshot {
    StatusSnapshot(
        state: .active, intent: .on, lidClosed: true, internetReachable: true,
        thermal: ThermalReading(level: .nominal, pressure: 0), temperatures: temperatures,
        power: PowerReading(onBattery: false, percent: 80), sleepDisabled: true, lastError: lastError,
        heartbeatAt: heartbeat)
}

@Suite struct F002ReviewRegressionTests {

    @Test("F-002 · R1 · with allowUnknownTemperatures the warning does not promise a pause")
    func warningRespectsAllowUnknownTemperatures() throws {
        let view = StatusView.make(
            snapshot: runningSnapshot(temperatures: TemperatureReading(batteryMaxC: nil, dieAverageC: nil)),
            intent: .on, liveSleepDisabled: true, now: heartbeat.addingTimeInterval(30),
            allowUnknownTemperatures: true)
        let warning = try #require(view.warnings.first)
        #expect(view.warnings.count == 1)
        #expect(warning.hasPrefix("heat protection is limited on this Mac:"))
        #expect(!warning.contains("pauses after 2 minutes"), "warning: \(warning)")
        #expect(warning.contains("allowUnknownTemperatures"), "warning: \(warning)")
    }

    @Test("F-002 · R2 · a relative PATH entry resolves against the current directory, like the shell")
    func relativePathEntryResolvesAgainstCurrentDirectory() {
        let result = InstallTarget.resolve(
            argv0: "agentmode", currentDirectory: "/Users/tester/work", pathVariable: "relbin:/other",
            override: nil,
            isExecutableFile: { ["/Users/tester/work/relbin/agentmode", "/other/agentmode"].contains($0) })
        #expect(result == .success("/Users/tester/work/relbin/agentmode"))
    }

    @Test("F-002 · R3 · `Heat protection` follows the whole of a multi-line last error")
    func heatProtectionFollowsMultiLineError() throws {
        let view = StatusView.make(
            snapshot: runningSnapshot(
                temperatures: TemperatureReading(batteryMaxC: 30, dieAverageC: 40),
                lastError: "sudo: parse error in /etc/sudoers.d/agentmode\nsudo: no valid sudoers sources found"),
            intent: .on, liveSleepDisabled: true, now: heartbeat.addingTimeInterval(30))
        let lines = view.text().components(separatedBy: "\n")
        let heat = try #require(lines.firstIndex(of: "Heat protection: full"))
        let secondErrorLine = try #require(lines.firstIndex(of: "sudo: no valid sudoers sources found"))
        #expect(heat == secondErrorLine + 1, "lines: \(lines)")
        #expect(lines[heat + 1].hasPrefix("Heartbeat:"), "lines: \(lines)")
    }
}
