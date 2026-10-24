import Foundation

public enum Predicates {
    /// `System Capabilities` bit of `IOPMrootDomain` that is set only when graphics are powered.
    static let graphicsCapability: UInt32 = 0x02
    /// Thermal pressure level `heavy`; `moderate` (1) alone does not trip.
    static let heavyThermalPressure: UInt64 = 2
    /// Readings outside this range are sensor errors, such as `PMU tdev1` reporting -9202 °C.
    static let validCelsius: ClosedRange<Double> = -20...150

    public static func isThermalTrip(_ r: ThermalReading) -> Bool {
        switch r.level {
        case .serious, .critical: true
        case .nominal, .fair: r.pressure >= heavyThermalPressure
        }
    }

    public static func isThermalCalm(_ r: ThermalReading) -> Bool {
        !isThermalTrip(r)
    }

    public static func batteryPercent(current: Int, max: Int) -> Int? {
        guard max > 0 else { return nil }
        return Int((Double(current) * 100 / Double(max)).rounded())
    }

    /// A dark wake lacks the graphics capability; with the lid closed only an external display makes it full.
    public static func isFullWake(capabilities: UInt32?, lidClosed: Bool, externalDisplayActive: Bool) -> Bool {
        guard let capabilities, capabilities & graphicsCapability != 0 else { return false }
        return !lidClosed || externalDisplayActive
    }

    public static func temperatureSummary(_ samples: [SensorSample]) -> TemperatureReading {
        let valid = samples.filter { validCelsius.contains($0.celsius) }
        func celsius(namedLike fragment: String) -> [Double] {
            valid.filter { $0.name.range(of: fragment, options: .caseInsensitive) != nil }.map(\.celsius)
        }
        let battery = celsius(namedLike: "battery")
        let die = celsius(namedLike: "tdie")

        return TemperatureReading(
            batteryMaxC: battery.max(),
            dieAverageC: die.isEmpty ? nil : die.reduce(0, +) / Double(die.count)
        )
    }
}

public enum ProbeEvaluator {
    /// Captive portals answer this host with their own login page instead of Apple's "Success" page.
    static let captiveHost = "captive.apple.com"

    public static func isReachable(url: URL, statusCode: Int?, body: String?) -> Bool {
        guard let statusCode else { return false }
        guard url.host(percentEncoded: false)?.lowercased() == captiveHost else { return true }
        return statusCode == 200 && body?.contains("Success") == true
    }
}
