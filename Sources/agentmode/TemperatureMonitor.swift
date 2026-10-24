import AgentModeCore
import CIOHIDPrivate
import Foundation

/// Real temperatures, the main P2 source (design §8.4): every 30 s the HID event system's temperature
/// sensors are read and summarized by `Predicates.temperatureSummary`. The API is private; if it fails,
/// the reading is unknown and the failure is logged once. With the lid closed and no external display,
/// the engine pauses after 2 minutes of unknown readings unless `allowUnknownTemperatures` is set.
@MainActor
final class TemperatureMonitor {
    static let interval: TimeInterval = 30

    private let emit: @MainActor (Event) -> Void
    private let reader = SensorReader()
    private var timer: Timer?
    private var reportedFailure = false

    init(emit: @escaping @MainActor (Event) -> Void) {
        self.emit = emit
    }

    func start() {
        timer = MainLoop.repeating(every: Self.interval, first: Self.interval) { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    func refresh() {
        reader.read { [weak self] samples in
            self?.deliver(samples)
        }
    }

    private func deliver(_ samples: [SensorSample]?) {
        let reading = Predicates.temperatureSummary(samples ?? [])
        let unknown = reading.batteryMaxC == nil && reading.dieAverageC == nil
        if unknown && !reportedFailure {
            Log.info(
                "temperatures: sensors are unreadable (private IOHIDEventSystemClient API); heat pauses rely on macOS thermal state, and with the lid closed and no external display the mode pauses after 2 minutes unless allowUnknownTemperatures is set"
            )
            reportedFailure = true
        } else if !unknown && reportedFailure {
            Log.info("temperatures: sensors are readable again")
            reportedFailure = false
        }
        emit(.temperatures(reading))
    }
}

/// Owns the HID client. It is created and used only on `queue`, which is what makes the
/// `@unchecked Sendable` safe; reading 40-odd sensors never runs on the daemon's main thread.
private final class SensorReader: @unchecked Sendable {
    /// `PrimaryUsagePage` and `PrimaryUsage` of temperature sensors (plan "Hechos de la fase Navigate").
    private static var matching: CFDictionary { ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary }
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    private let queue = DispatchQueue(label: "com.jsanchez.agentmode.temperatures", qos: .utility)
    private var client: IOHIDEventSystemClient?

    /// `completion` runs on the main thread with `nil` when the API is unavailable.
    func read(completion: @escaping @MainActor @Sendable ([SensorSample]?) -> Void) {
        queue.async {
            let samples = self.readOnQueue()
            MainLoop.async { completion(samples) }
        }
    }

    private func readOnQueue() -> [SensorSample]? {
        // A macOS that dropped one of the private functions leaves it unbound (weak import).
        guard CIOHIDPrivateIsAvailable() else { return nil }
        if client == nil, let created = IOHIDEventSystemClientCreate(kCFAllocatorDefault) {
            IOHIDEventSystemClientSetMatching(created, Self.matching)
            client = created
        }
        guard let client, let services = IOHIDEventSystemClientCopyServices(client) else {
            return nil
        }
        var samples: [SensorSample] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let pointer = CFArrayGetValueAtIndex(services, index) else { continue }
            // The array owns its services; this reference does not.
            let service = Unmanaged<IOHIDServiceClient>.fromOpaque(pointer).takeUnretainedValue()
            guard let event = IOHIDServiceClientCopyEvent(service, Self.temperatureEvent, 0, 0) else { continue }
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? ""
            samples.append(SensorSample(name: name, celsius: IOHIDEventGetFloatValue(event, Self.temperatureField)))
        }
        return samples
    }
}
