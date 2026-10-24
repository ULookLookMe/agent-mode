import AgentModeCore
import Darwin
import Foundation
import notify

/// macOS's own heat signals, the secondary P2 sources (design §8.4): `ProcessInfo.thermalState` and the
/// thermal pressure level published under `com.apple.system.thermalpressurelevel`.
@MainActor
final class ThermalMonitor {
    private let emit: @MainActor (Event) -> Void
    private var observer: (any NSObjectProtocol)?
    private var pressureToken: Int32?
    private var last: ThermalReading?

    init(emit: @escaping @MainActor (Event) -> Void) {
        self.emit = emit
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        var token: Int32 = 0
        let status = notify_register_dispatch(kOSThermalNotificationPressureLevelName, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if status == NOTIFY_STATUS_OK {
            pressureToken = token
        } else {
            Log.info("thermal: notify_register_dispatch failed (\(status)), pressure reads as nominal")
        }
        refresh()
    }

    /// Reports the reading when it changed since the last report.
    func refresh() {
        let reading = ThermalReading(level: Self.level(), pressure: pressure())
        guard reading != last else { return }
        last = reading
        emit(.thermal(reading))
    }

    private func pressure() -> UInt64 {
        guard let pressureToken else { return 0 }
        var value: UInt64 = 0
        return notify_get_state(pressureToken, &value) == NOTIFY_STATUS_OK ? value : 0
    }

    private static func level() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        // A state newer than this code is treated as the worst known one.
        @unknown default: .critical
        }
    }
}
