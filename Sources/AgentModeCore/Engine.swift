import Foundation

/// The agent-mode state machine (design §8.2–§8.4). It is pure: the daemon feeds it system events with
/// their time and executes the returned actions in order.
public struct Engine: Sendable {
    public private(set) var state: ModeState = .off
    public private(set) var intent: Intent = .off
    public private(set) var lastError: String?

    let config: AgentModeConfig

    /// A pause resumes only after the wake has stayed full this long, so a DarkWake never counts (A6).
    static let fullWakeHold: TimeInterval = 10
    /// How long no temperature sensor may be readable with the lid shut before the mode pauses (F-002 §3.5).
    static let sensorsGrace: TimeInterval = 120

    private var lidClosed: Bool?
    private var externalDisplayActive = false
    private var thermal: ThermalReading?
    private var temperatures: TemperatureReading?
    private var power: PowerReading?
    private var internetFailingSince: Date?
    private var dieHotSince: Date?
    /// The first unreadable temperature reading since the last readable one; `nil` while sensors read.
    private var sensorsUnreadableSince: Date?
    private var thermalCalmSince: Date?
    private var fullWakeSince: Date?
    /// The last wake report; `nil` until the first one.
    private var lastFullWake: Bool?
    /// What the previous daemon saved, until `.startup` consumes it.
    private var savedState: ModeState?
    private var started = false

    public init(config: AgentModeConfig) {
        self.config = config
    }

    public mutating func handle(_ event: Event, at now: Date) -> [Action] {
        var effects = Effects()
        switch event {
        case .savedState(let saved):
            if !started {
                savedState = saved
            }
        case .startup(let intent, let sleepDisabled):
            startup(intent: intent, sleepDisabled: sleepDisabled, at: now, &effects)
        case .intent(.on):
            turnOn(at: now, &effects)
        case .intent(.off):
            turnOff(&effects)
        case .lid(let closed):
            let justClosed = closed && lidClosed != true
            lidClosed = closed
            forgetFullWakeIfLidShut()
            evaluate(at: now, &effects)
            if justClosed && state == .active && !externalDisplayActive {
                effects.turnDisplayOff = true
            }
        case .externalDisplay(let active):
            let justRemoved = externalDisplayActive && !active
            externalDisplayActive = active
            forgetFullWakeIfLidShut()
            evaluate(at: now, &effects)
            // Unplugging the monitor of a closed Mac leaves only the built-in panel, lit behind the lid.
            if justRemoved && lidClosed == true && state == .active {
                effects.turnDisplayOff = true
            }
        case .probe(let reachable):
            internetFailingSince = reachable ? nil : (internetFailingSince ?? now)
            evaluate(at: now, &effects)
        case .thermal(let reading):
            thermal = reading
            updateThermalCalm(at: now)
            evaluate(at: now, &effects)
        case .temperatures(let reading):
            temperatures = reading
            let unreadable = reading.batteryMaxC == nil && reading.dieAverageC == nil
            sensorsUnreadableSince = unreadable ? (sensorsUnreadableSince ?? now) : nil
            // An unknown die reading neither starts nor clears the sustain window.
            if let die = reading.dieAverageC {
                dieHotSince = die >= config.dieAverageMaxCelsius ? (dieHotSince ?? now) : nil
            }
            updateThermalCalm(at: now)
            evaluate(at: now, &effects)
        case .power(let reading):
            power = reading
            evaluate(at: now, &effects)
        case .fullWake(let full):
            lastFullWake = full
            fullWakeSince = full ? (fullWakeSince ?? now) : nil
            evaluate(at: now, &effects)
        case .tick(let sleepDisabled):
            evaluate(at: now, &effects)
            selfHeal(reported: sleepDisabled, &effects)
        case .applyFailed(let message):
            applyFailed(message, &effects)
        case .terminating:
            effects.sleepDisabled = false
            effects.logs.append("terminating: restoring sleep")
        }
        return effects.actions
    }
}

// MARK: - Transitions

extension Engine {
    /// Reapplies the mode after the daemon starts (design §8.3): a saved pause stays paused, and the mode
    /// becomes ACTIVE again only where a resume could (A6), unless `SleepDisabled` is still 1, which means
    /// the Mac never slept since the previous daemon kept it awake.
    private mutating func startup(intent: Intent, sleepDisabled: Bool?, at now: Date, _ effects: inout Effects) {
        started = true
        self.intent = intent
        let saved = savedState
        savedState = nil
        switch intent {
        case .off:
            state = .off
        case .on:
            restartInternetTimer(at: now)
            let tripped = trippedReasons(at: now)
            if case .paused(let savedReasons) = saved {
                state = .paused(tripped.union(savedReasons))
            } else if !tripped.isEmpty {
                state = .paused(tripped)
            } else if sleepDisabled != true && !mayBeFullWake {
                state = .paused([])
            } else {
                state = .active
            }
        }
        let target = state == .active
        if sleepDisabled != target {
            if target {
                effects.sleepDisabled = true
            } else {
                restoreSleep(&effects)
            }
        }
        if target && lidClosed == true && !externalDisplayActive {
            effects.turnDisplayOff = true
        }
        effects.logs.append("startup: intent \(intent.rawValue), \(Self.describe(state))")
    }

    private mutating func turnOn(at now: Date, _ effects: inout Effects) {
        guard intent == .off else { return }
        intent = .on
        lastError = nil
        restartInternetTimer(at: now)
        let tripped = trippedReasons(at: now)
        if tripped.isEmpty {
            state = .active
            effects.sleepDisabled = true
            effects.notice = .activated
            effects.logs.append("activated")
        } else {
            state = .paused(tripped)
            effects.notice = .paused(tripped)
            effects.logs.append("turned on while tripped: \(Self.describe(state))")
        }
    }

    private mutating func turnOff(_ effects: inout Effects) {
        guard intent == .on else { return }
        if state == .active {
            leaveActive(&effects)
        }
        intent = .off
        state = .off
        effects.notice = .deactivated
        effects.logs.append("deactivated")
    }

    private mutating func applyFailed(_ message: String, _ effects: inout Effects) {
        // A failing self-heal while OFF repeats every tick; one notification per distinct error is enough.
        let alreadyReported = state == .off && lastError == message
        if state == .active {
            leaveActive(&effects)
        }
        intent = .off
        state = .off
        lastError = message
        if !alreadyReported {
            effects.notice = .error(message)
        }
        effects.logs.append("could not apply SleepDisabled, mode off: \(message)")
    }

    /// Applies automatic pauses and resumes (design §4 G5/G6, §8.2) after the latest readings.
    private mutating func evaluate(at now: Date, _ effects: inout Effects) {
        switch state {
        case .off:
            return
        case .active:
            let tripped = trippedReasons(at: now)
            guard !tripped.isEmpty else { return }
            leaveActive(&effects)
            state = .paused(tripped)
            effects.notice = .paused(tripped)
            effects.logs.append(Self.describe(state))
        case .paused(let reasons):
            let remaining = reasons.union(trippedReasons(at: now)).filter { !hasRecovered($0, at: now) }
            if remaining.isEmpty && Self.held(since: fullWakeSince, for: Self.fullWakeHold, at: now) {
                state = .active
                effects.sleepDisabled = true
                effects.notice = .resumed
                effects.logs.append("resumed")
            } else if remaining != reasons {
                state = .paused(remaining)
                effects.logs.append(Self.describe(state))
            }
        }
    }

    private func leaveActive(_ effects: inout Effects) {
        restoreSleep(&effects)
    }

    /// Restores normal sleep. With the lid closed, clearing `disablesleep` does not sleep the Mac by
    /// itself, so it is put to sleep explicitly (design §8.3), unless an external display shows the Mac is
    /// in use in clamshell mode (A5).
    private func restoreSleep(_ effects: inout Effects) {
        effects.sleepDisabled = false
        effects.sleepNow = lidClosed == true && !externalDisplayActive
    }

    /// macOS can reset `SleepDisabled` behind our back (design §8.3), so every tick compares it with the
    /// state. A restore that failed earlier also lands here, so clearing it sleeps a closed Mac too.
    private func selfHeal(reported: Bool?, _ effects: inout Effects) {
        guard effects.sleepDisabled == nil, let reported else { return }
        let target = state == .active
        guard reported != target else { return }
        if target {
            effects.sleepDisabled = true
        } else {
            restoreSleep(&effects)
        }
        effects.logs.append("self-heal: SleepDisabled was \(reported ? 1 : 0), setting \(target ? 1 : 0)")
    }
}

// MARK: - Conditions

extension Engine {
    private func trippedReasons(at now: Date) -> Set<PauseReason> {
        var reasons: Set<PauseReason> = []
        if Self.held(since: internetFailingSince, for: Self.seconds(minutes: config.internetTimeoutMinutes), at: now) {
            reasons.insert(.noInternet)
        }
        if isHot(at: now) {
            reasons.insert(.thermal)
        }
        if let power, power.onBattery, let percent = power.percent, percent <= config.batteryFloorPercent {
            reasons.insert(.lowBattery)
        }
        if !config.allowUnknownTemperatures && isShutWithoutDisplay
            && Self.held(since: sensorsUnreadableSince, for: Self.sensorsGrace, at: now)
        {
            reasons.insert(.sensorsUnavailable)
        }
        return reasons
    }

    private func hasRecovered(_ reason: PauseReason, at now: Date) -> Bool {
        switch reason {
        case .noInternet:
            internetFailingSince == nil
        case .thermal:
            Self.held(since: thermalCalmSince, for: Self.seconds(minutes: config.thermalResumeMinutes), at: now)
        case .lowBattery:
            power?.onBattery == false
        case .sensorsUnavailable:
            sensorsUnreadableSince == nil || !isShutWithoutDisplay
        }
    }

    private func isHot(at now: Date) -> Bool {
        if let thermal, Predicates.isThermalTrip(thermal) {
            return true
        }
        if let battery = temperatures?.batteryMaxC, battery >= config.batteryMaxCelsius {
            return true
        }
        if let die = temperatures?.dieAverageC, die >= config.dieAverageMaxCelsius {
            return Self.held(since: dieHotSince, for: Self.seconds(minutes: config.dieSustainMinutes), at: now)
        }
        return false
    }

    /// Calm sits `resumeMarginCelsius` below each trip so readings hovering at a threshold do not flap.
    /// Unknown readings never block calm.
    private var isCalm: Bool {
        let margin = config.resumeMarginCelsius
        let macOSCalm = thermal.map(Predicates.isThermalCalm) ?? true
        let batteryCalm = temperatures?.batteryMaxC.map { $0 < config.batteryMaxCelsius - margin } ?? true
        let dieCalm = temperatures?.dieAverageC.map { $0 < config.dieAverageMaxCelsius - margin } ?? true
        return macOSCalm && batteryCalm && dieCalm
    }

    private mutating func updateThermalCalm(at now: Date) {
        thermalCalmSince = isCalm ? (thermalCalmSince ?? now) : nil
    }

    /// P1 counts from the later of the first failed probe and `on` (design §8.2).
    private mutating func restartInternetTimer(at now: Date) {
        if internetFailingSince != nil {
            internetFailingSince = now
        }
    }

    /// Whether the readings so far allow a full wake (design §8.4): unknown readings do, a reported
    /// partial wake or a shut lid without an external display do not.
    private var mayBeFullWake: Bool {
        lastFullWake != false && !isShutWithoutDisplay
    }

    /// The lid is known to be closed and no external display is in use: nobody can see or cool the Mac.
    private var isShutWithoutDisplay: Bool {
        lidClosed == true && !externalDisplayActive
    }

    /// With the lid shut and no external display the Mac cannot be in a full wake (design §8.4), so a
    /// pending resume has to wait for the next one (A6).
    private mutating func forgetFullWakeIfLidShut() {
        if lidClosed == true && !externalDisplayActive {
            fullWakeSince = nil
        }
    }

    private static func held(since start: Date?, for duration: TimeInterval, at now: Date) -> Bool {
        guard let start else { return false }
        return now.timeIntervalSince(start) >= duration
    }

    private static func seconds(minutes: Int) -> TimeInterval {
        TimeInterval(minutes) * 60
    }

    private static func describe(_ state: ModeState) -> String {
        switch state {
        case .off:
            "off"
        case .active:
            "active"
        case .paused(let reasons) where reasons.isEmpty:
            "paused: waiting for a full wake"
        case .paused(let reasons):
            "paused: " + reasons.sorted().map(\.rawValue).joined(separator: ", ")
        }
    }
}

/// The effects of one event, emitted in a fixed order: sleep setting, sleep now, display off,
/// notification, then log lines (plan, Tarea 2).
private struct Effects {
    var sleepDisabled: Bool?
    var sleepNow = false
    var turnDisplayOff = false
    var notice: Notice?
    var logs: [String] = []

    var actions: [Action] {
        var actions: [Action] = []
        if let sleepDisabled {
            actions.append(.setSleepDisabled(sleepDisabled))
        }
        if sleepNow {
            actions.append(.sleepNow)
        }
        if turnDisplayOff {
            actions.append(.turnDisplayOff)
        }
        if let notice {
            actions.append(.notify(notice))
        }
        return actions + logs.map(Action.log)
    }
}
