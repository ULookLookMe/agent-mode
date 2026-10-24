import Foundation
import Testing

@testable import AgentModeCore

/// Whether `status` reports the daemon as running (design G7). Regression for a review finding: a daemon
/// that exited still looked alive for 2 min. Added after the frozen contract; approved with it.
@Suite struct DaemonLivenessTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func snapshot(heartbeatAt: Date, stoppedAt: Date?) -> StatusSnapshot {
        StatusSnapshot(
            state: .active,
            intent: .on,
            lidClosed: false,
            internetReachable: true,
            thermal: nil,
            temperatures: nil,
            power: nil,
            sleepDisabled: true,
            lastError: nil,
            heartbeatAt: heartbeatAt,
            stoppedAt: stoppedAt
        )
    }

    @Test func freshHeartbeatMeansRunning() {
        #expect(snapshot(heartbeatAt: t0, stoppedAt: nil).isDaemonRunning(at: t0.addingTimeInterval(119)))
    }

    @Test func staleHeartbeatMeansNotRunning() {
        #expect(!snapshot(heartbeatAt: t0, stoppedAt: nil).isDaemonRunning(at: t0.addingTimeInterval(120)))
    }

    @Test func stoppedDaemonIsNotRunningDespiteFreshHeartbeat() {
        #expect(!snapshot(heartbeatAt: t0, stoppedAt: t0).isDaemonRunning(at: t0.addingTimeInterval(1)))
    }

    /// `status.json` written before `stoppedAt` existed still decodes.
    @Test func statusWithoutStoppedAtDecodes() throws {
        let json = #"{"heartbeatAt":"2026-10-17T00:30:46Z","intent":"on","state":{"active":{}}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StatusSnapshot.self, from: Data(json.utf8))
        #expect(decoded.stoppedAt == nil)
        #expect(decoded.state == .active)
    }
}
