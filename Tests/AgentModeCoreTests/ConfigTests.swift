import Foundation
import Testing

@testable import AgentModeCore

/// Contract for `AgentModeConfig` (design §8.5; plan "Restricciones globales").
@Suite struct ConfigTests {
    static let anthropicURL = "https://api.anthropic.com"
    static let captiveURL = "https://captive.apple.com/hotspot-detect.html"

    /// The nine default values written in the spec, built independently of `AgentModeConfig.default`.
    static func specDefaults(batteryFloorPercent: Int = 10) throws -> AgentModeConfig {
        AgentModeConfig(
            internetTimeoutMinutes: 10,
            probeIntervalSeconds: 60,
            probeURLs: [try #require(URL(string: anthropicURL)), try #require(URL(string: captiveURL))],
            thermalResumeMinutes: 5,
            batteryFloorPercent: batteryFloorPercent,
            batteryMaxCelsius: 40,
            dieAverageMaxCelsius: 80,
            dieSustainMinutes: 5,
            resumeMarginCelsius: 5
        )
    }

    @Test func defaultsMatchSpec() throws {
        let config = AgentModeConfig.default

        #expect(config.internetTimeoutMinutes == 10)
        #expect(config.probeIntervalSeconds == 60)
        #expect(config.probeURLs.map(\.absoluteString) == [Self.anthropicURL, Self.captiveURL])
        #expect(config.thermalResumeMinutes == 5)
        #expect(config.batteryFloorPercent == 10)
        #expect(config.batteryMaxCelsius == 40)
        #expect(config.dieAverageMaxCelsius == 80)
        #expect(config.dieSustainMinutes == 5)
        #expect(config.resumeMarginCelsius == 5)
    }

    @Test func partialJSONFallsBackToDefaults() throws {
        let json = Data(#"{"batteryFloorPercent": 20}"#.utf8)

        let config = try JSONDecoder().decode(AgentModeConfig.self, from: json)

        #expect(config.batteryFloorPercent == 20)
        #expect(config == (try Self.specDefaults(batteryFloorPercent: 20)))
    }

    // Edge of the same rule: with every key absent, decoding yields the spec defaults.
    @Test func emptyJSONYieldsDefaults() throws {
        let config = try JSONDecoder().decode(AgentModeConfig.self, from: Data("{}".utf8))

        #expect(config == (try Self.specDefaults()))
    }
}
