/// Notification texts in the user's language (F-002 design §3.4): Spanish when it is the first preferred
/// language, English otherwise.
public enum NoticeText {
    public static func text(for notice: Notice, preferredLanguages: [String]) -> String {
        let spanish = preferredLanguages.first?.lowercased().hasPrefix("es") == true
        return spanish ? Spanish.text(for: notice) : English.text(for: notice)
    }

    private enum English {
        static func text(for notice: Notice) -> String {
            switch notice {
            case .activated:
                "Agent mode on"
            case .paused(let reasons) where reasons.isEmpty:
                "Agent mode paused: waiting for a full wake"
            case .paused(let reasons):
                "Agent mode paused: " + names(reasons, name)
            case .resumed:
                "Agent mode resumed"
            case .deactivated:
                "Agent mode off"
            case .error(let message):
                "Agent mode error: \(message)"
            }
        }

        static func name(_ reason: PauseReason) -> String {
            switch reason {
            case .noInternet: "no internet"
            case .thermal: "heat"
            case .lowBattery: "low battery"
            case .sensorsUnavailable: "temperature sensors unreadable"
            }
        }
    }

    private enum Spanish {
        static func text(for notice: Notice) -> String {
            switch notice {
            case .activated:
                "Modo agente activado"
            case .paused(let reasons) where reasons.isEmpty:
                "Modo agente en pausa: esperando un despertar completo"
            case .paused(let reasons):
                "Modo agente en pausa: " + names(reasons, name)
            case .resumed:
                "Modo agente reanudado"
            case .deactivated:
                "Modo agente apagado"
            case .error(let message):
                "Modo agente: error: \(message)"
            }
        }

        static func name(_ reason: PauseReason) -> String {
            switch reason {
            case .noInternet: "sin internet"
            case .thermal: "calor"
            case .lowBattery: "batería baja"
            case .sensorsUnavailable: "sensores de temperatura ilegibles"
            }
        }
    }

    /// Reasons in declaration order, which follows the design's P1, P2, P3 numbering.
    private static func names(_ reasons: Set<PauseReason>, _ name: (PauseReason) -> String) -> String {
        PauseReason.allCases.filter(reasons.contains).map(name).joined(separator: ", ")
    }
}
