import Foundation

public struct AgentModeConfig: Codable, Equatable, Sendable {
    public var internetTimeoutMinutes: Int
    public var probeIntervalSeconds: Int
    public var probeURLs: [URL]
    public var thermalResumeMinutes: Int
    public var batteryFloorPercent: Int
    public var batteryMaxCelsius: Double
    public var dieAverageMaxCelsius: Double
    public var dieSustainMinutes: Int
    public var resumeMarginCelsius: Double
    public var allowUnknownTemperatures: Bool

    public init(
        internetTimeoutMinutes: Int,
        probeIntervalSeconds: Int,
        probeURLs: [URL],
        thermalResumeMinutes: Int,
        batteryFloorPercent: Int,
        batteryMaxCelsius: Double,
        dieAverageMaxCelsius: Double,
        dieSustainMinutes: Int,
        resumeMarginCelsius: Double,
        allowUnknownTemperatures: Bool = false
    ) {
        self.internetTimeoutMinutes = internetTimeoutMinutes
        self.probeIntervalSeconds = probeIntervalSeconds
        self.probeURLs = probeURLs
        self.thermalResumeMinutes = thermalResumeMinutes
        self.batteryFloorPercent = batteryFloorPercent
        self.batteryMaxCelsius = batteryMaxCelsius
        self.dieAverageMaxCelsius = dieAverageMaxCelsius
        self.dieSustainMinutes = dieSustainMinutes
        self.resumeMarginCelsius = resumeMarginCelsius
        self.allowUnknownTemperatures = allowUnknownTemperatures
    }

    public static let `default` = AgentModeConfig(
        internetTimeoutMinutes: 10,
        probeIntervalSeconds: 60,
        probeURLs: [
            URL(string: "https://api.anthropic.com")!,
            URL(string: "https://captive.apple.com/hotspot-detect.html")!,
        ],
        thermalResumeMinutes: 5,
        batteryFloorPercent: 10,
        batteryMaxCelsius: 40,
        dieAverageMaxCelsius: 80,
        dieSustainMinutes: 5,
        resumeMarginCelsius: 5
    )

    /// A config file only needs the keys it overrides: absent or null keys keep their default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default

        func value<T: Decodable>(_ key: CodingKeys, or defaultValue: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? defaultValue
        }

        self.init(
            internetTimeoutMinutes: try value(.internetTimeoutMinutes, or: fallback.internetTimeoutMinutes),
            probeIntervalSeconds: try value(.probeIntervalSeconds, or: fallback.probeIntervalSeconds),
            probeURLs: try value(.probeURLs, or: fallback.probeURLs),
            thermalResumeMinutes: try value(.thermalResumeMinutes, or: fallback.thermalResumeMinutes),
            batteryFloorPercent: try value(.batteryFloorPercent, or: fallback.batteryFloorPercent),
            batteryMaxCelsius: try value(.batteryMaxCelsius, or: fallback.batteryMaxCelsius),
            dieAverageMaxCelsius: try value(.dieAverageMaxCelsius, or: fallback.dieAverageMaxCelsius),
            dieSustainMinutes: try value(.dieSustainMinutes, or: fallback.dieSustainMinutes),
            resumeMarginCelsius: try value(.resumeMarginCelsius, or: fallback.resumeMarginCelsius),
            allowUnknownTemperatures: try value(.allowUnknownTemperatures, or: fallback.allowUnknownTemperatures)
        )
    }
}
