import Foundation
import Testing

@testable import AgentModeCore

// F-002 design §3.4: notification texts in the user's language.
// Contract tests written from the spec and the public interfaces only.

@Suite struct F002NoticeTextTests {

    @Test(
        "F-002 · E43 · English texts, pause reasons in allCases order separated by commas",
        arguments: [
            (Notice.activated, "Agent mode on"),
            (.paused([]), "Agent mode paused: waiting for a full wake"),
            (.paused([.noInternet]), "Agent mode paused: no internet"),
            (.paused([.thermal]), "Agent mode paused: heat"),
            (.paused([.lowBattery]), "Agent mode paused: low battery"),
            (.paused([.sensorsUnavailable]), "Agent mode paused: temperature sensors unreadable"),
            (.paused([.lowBattery, .noInternet]), "Agent mode paused: no internet, low battery"),
            (
                .paused([.sensorsUnavailable, .lowBattery, .thermal, .noInternet]),
                "Agent mode paused: no internet, heat, low battery, temperature sensors unreadable"
            ),
            (.resumed, "Agent mode resumed"),
            (.deactivated, "Agent mode off"),
            (.error("pmset: fictional failure"), "Agent mode error: pmset: fictional failure"),
        ]
    )
    func englishTexts(notice: Notice, expected: String) {
        #expect(NoticeText.text(for: notice, preferredLanguages: ["en-US"]) == expected)
    }

    @Test(
        "F-002 · E44 · Spanish texts, pause reasons in allCases order separated by commas",
        arguments: [
            (Notice.activated, "Modo agente activado"),
            (.paused([]), "Modo agente en pausa: esperando un despertar completo"),
            (.paused([.noInternet]), "Modo agente en pausa: sin internet"),
            (.paused([.thermal]), "Modo agente en pausa: calor"),
            (.paused([.lowBattery]), "Modo agente en pausa: batería baja"),
            (.paused([.sensorsUnavailable]), "Modo agente en pausa: sensores de temperatura ilegibles"),
            (.paused([.lowBattery, .noInternet]), "Modo agente en pausa: sin internet, batería baja"),
            (
                .paused([.sensorsUnavailable, .lowBattery, .thermal, .noInternet]),
                "Modo agente en pausa: sin internet, calor, batería baja, sensores de temperatura ilegibles"
            ),
            (.resumed, "Modo agente reanudado"),
            (.deactivated, "Modo agente apagado"),
            (.error("pmset: fallo ficticio"), "Modo agente: error: pmset: fallo ficticio"),
        ]
    )
    func spanishTexts(notice: Notice, expected: String) {
        #expect(NoticeText.text(for: notice, preferredLanguages: ["es-CO"]) == expected)
    }

    @Test(
        "F-002 · E45 · Spanish only when the first language, lowercased, starts with `es`; otherwise English",
        arguments: [
            (["es"], true),
            (["es-CO"], true),
            (["ES-MX"], true),
            (["Es-419"], true),
            (["es-CO", "en-US"], true),
            (["en-US", "es-CO"], false),
            (["en"], false),
            (["fr-FR"], false),
            (["pt-BR", "es"], false),
            ([], false),
        ] as [([String], Bool)]
    )
    func languageFollowsFirstPreference(languages: [String], spanish: Bool) {
        #expect(
            NoticeText.text(for: .activated, preferredLanguages: languages)
                == (spanish ? "Modo agente activado" : "Agent mode on")
        )
    }
}
