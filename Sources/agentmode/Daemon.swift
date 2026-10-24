import AgentModeCore
import Foundation
import notify

/// The resident process (design §8.1). It turns system signals into `Event`s for the pure `Engine`,
/// executes the `Action`s it returns and keeps `status.json` current. Everything runs on the main
/// thread, whose run loop (`CFRunLoopRun()`) delivers IOKit, IOPS, timer and dispatch callbacks; slow
/// work (commands, HTTPS probes, sensor reads) runs elsewhere and hops back.
@MainActor
final class Daemon {
    /// The tick runs the self-heal, which must bring `SleepDisabled` back within 60 s (AC4): a 30 s
    /// period plus the timer's tolerance plus `sudo pmset` and its verification stays well under it.
    static let tickInterval: TimeInterval = 30
    /// The first tick comes soon after start: it refreshes the heartbeat and lets a resume that only
    /// waits for the 10 s full-wake hold complete.
    static let firstTick: TimeInterval = 10.5
    // Termination budget, well under the LaunchAgent's ExitTimeOut of 10 s (A1): at most 1 + 1 + 0.5 s
    // for commands already running, then 4 + 2 s for the final `disablesleep 0`.
    static let terminationGrace: TimeInterval = 1
    static let terminationStopTimeout: TimeInterval = 1
    static let terminationCommandTimeout: TimeInterval = 4
    static let terminationVerifyTimeout: TimeInterval = 2

    private let runtime: Runtime
    private var engine: Engine
    private let config: AgentModeConfig

    private lazy var applier: SleepSettingApplier = SleepSettingApplier(
        onSuccess: { [unowned self] disabled in
            Log.info(SleepSettings.appliedMessage(disabled))
            self.writeStatus()
        },
        onFailure: { [unowned self] reason in
            Log.info("SleepDisabled change failed: \(reason)")
            self.handle(.applyFailed(reason))
        }
    )
    private lazy var displays: DisplayController = DisplayController(
        dryRun: runtime.dryRun,
        stillWanted: { [unowned self] in
            self.lidMonitor.closed == true && !self.displays.externalActive && self.engine.state == .active
        },
        emit: { [unowned self] in self.handle($0) }
    )
    private lazy var lidMonitor: LidMonitor = LidMonitor { [unowned self] in self.handle($0) }
    private lazy var wakeMonitor: WakeMonitor = WakeMonitor(
        lidClosed: { [unowned self] in self.lidMonitor.closed },
        externalDisplayActive: { [unowned self] in self.displays.externalActive },
        emit: { [unowned self] in self.handle($0) }
    )
    private lazy var powerMonitor: PowerMonitor = PowerMonitor { [unowned self] in self.handle($0) }
    private lazy var thermalMonitor: ThermalMonitor = ThermalMonitor { [unowned self] in self.handle($0) }
    private lazy var temperatureMonitor: TemperatureMonitor = TemperatureMonitor { [unowned self] in self.handle($0) }
    private lazy var networkMonitor: NetworkMonitor = NetworkMonitor(config: config) { [unowned self] in self.handle($0)
    }

    private var intentToken: Int32?
    private var signalSources: [any DispatchSourceSignal] = []
    private var tickTimer: Timer?
    private var started = false
    /// Set once the engine handled `.startup`; until then `status.json` keeps what the previous daemon saved.
    private var startedUp = false
    private var terminating = false
    private var reportedStatusWriteFailure = false
    /// `intent.json` as last read or written here.
    private var intentFile: StateFiles.IntentFile?
    private var sleepNowRunning = false

    // The latest readings, for status.json.
    private var lidClosed: Bool?
    private var internetReachable: Bool?
    private var thermal: ThermalReading?
    private var temperatures: TemperatureReading?
    private var power: PowerReading?

    init(runtime: Runtime) {
        self.runtime = runtime
        config = StateFiles.loadConfig(runtime)
        engine = Engine(config: config)
    }

    func run() -> Never {
        Log.info(
            "daemon starting, pid \(getpid())\(runtime.dryRun ? ", dry run in \(runtime.stateDirectory.path(percentEncoded: false))" : "")"
        )
        installSignalHandlers()
        // Registered before the first read, so a change posted in between is not lost.
        registerForIntentChanges()
        let intent = readIntentFile()?.intent ?? .off
        let saved = StateFiles.readStatus(runtime)

        // The startup decision needs the lid, the displays, power, heat and the wake state, so a restart
        // in a DarkWake never re-activates the mode (A6). The external display goes first: a closed lid
        // must never turn off a display in use (A5).
        displays.start()
        lidMonitor.start()
        powerMonitor.start()
        thermalMonitor.start()
        wakeMonitor.start()
        // A command written after the saved state supersedes it: `on` while the daemon was down starts afresh.
        if let saved, let record = intentFile?.record, saved.heartbeatAt > record.updatedAt {
            handle(.savedState(saved.state))
        }
        handle(.startup(intent: intent, sleepDisabled: RootDomain.sleepDisabled))

        temperatureMonitor.start()
        networkMonitor.start()
        tickTimer = MainLoop.repeating(every: Self.tickInterval, first: Self.firstTick) { [weak self] in
            self?.tick()
        }
        started = true

        CFRunLoopRun()
        Log.info("run loop stopped, exiting")
        exit(0)
    }

    // MARK: Events

    private func handle(_ event: Event) {
        guard !terminating else { return }
        record(event)
        let actions = engine.handle(event, at: Date())
        Log.info("event \(Self.describe(event)) -> \(Self.describe(engine.state))")
        if case .startup = event {
            startedUp = true
        }
        execute(actions)
        persistEngineIntent()
        writeStatus()
        // The lid and the external display decide whether this is a full wake (design §8.4).
        switch event {
        case .lid, .externalDisplay:
            if started {
                wakeMonitor.evaluate()
            }
        default:
            break
        }
    }

    private func record(_ event: Event) {
        switch event {
        case .lid(let closed): lidClosed = closed
        case .probe(let reachable): internetReachable = reachable
        case .thermal(let reading): thermal = reading
        case .temperatures(let reading): temperatures = reading
        case .power(let reading): power = reading
        default: break
        }
    }

    private func tick() {
        // Catch changes whose notification was missed, then let the engine check its timers.
        displays.refresh()
        powerMonitor.refresh()
        thermalMonitor.refresh()
        wakeMonitor.evaluate()
        handle(.tick(sleepDisabled: RootDomain.sleepDisabled))
    }

    private func readIntentFile() -> StateFiles.IntentFile? {
        do {
            let file = try StateFiles.readIntentFile(runtime)
            intentFile = file
            return file
        } catch {
            Log.info("cannot read \(runtime.intentURL.path(percentEncoded: false)): \(error)")
            return nil
        }
    }

    /// The engine turns the mode off by itself when applying `SleepDisabled` fails (design §8.3). The
    /// intent must say so too, or `toggle` would turn the mode off again instead of on, and the next
    /// start of the daemon would silently re-activate it.
    private func persistEngineIntent() {
        // Before `.startup` the engine has no intent of its own yet.
        guard startedUp, let seen = intentFile, seen.intent != engine.intent else { return }
        do {
            if let written = try StateFiles.replaceIntent(engine.intent, ifUnchangedSince: seen, runtime) {
                intentFile = written
                Log.info("saved intent \(engine.intent.rawValue): the mode changed without a command")
            } else {
                Log.info("intent not saved: a newer command is on its way")
            }
        } catch {
            Log.info("cannot write \(runtime.intentURL.path(percentEncoded: false)): \(error)")
        }
    }

    private func registerForIntentChanges() {
        var token: Int32 = 0
        let status = notify_register_dispatch(runtime.changeNotificationName, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let file = self.readIntentFile() else { return }
                self.handle(.intent(file.intent))
            }
        }
        if status == NOTIFY_STATUS_OK {
            intentToken = token
        } else {
            Log.info(
                "notify_register_dispatch(\(runtime.changeNotificationName)) failed (\(status)); on/off reach the daemon only on restart"
            )
        }
    }

    // MARK: Actions

    private func execute(_ actions: [Action]) {
        for action in actions {
            switch action {
            case .setSleepDisabled(let disabled):
                Log.info("action: set SleepDisabled \(disabled ? 1 : 0)")
                applier.request(disabled)
            case .sleepNow:
                Log.info("action: sleep now")
                // `disablesleep 0` must land first, or the Mac cannot sleep.
                applier.afterPendingChanges { [weak self] in self?.sleepNow() }
            case .turnDisplayOff:
                Log.info("action: turn the built-in display off")
                displays.turnDisplayOff()
            case .notify(let notice):
                Log.info("action: notify \"\(Notifier.text(for: notice))\"")
                Notifier.post(notice)
            case .log(let message):
                Log.info("engine: \(message)")
            }
        }
    }

    private func sleepNow() {
        // The lid may have opened, a display been plugged in or the mode resumed while `disablesleep 0` ran.
        guard lidMonitor.closed == true, !displays.externalActive, engine.state != .active else {
            Log.info("not sleeping: the lid is open, an external display is in use or the mode is active")
            return
        }
        // With `SleepDisabled` still 1 (the change failed) `sleepnow` does nothing; the self-heal clears it
        // on a later tick and asks for sleep again.
        if !runtime.dryRun && RootDomain.sleepDisabled != false {
            Log.info("not sleeping: SleepDisabled is not 0")
            return
        }
        guard !sleepNowRunning else { return }
        sleepNowRunning = true
        SleepSettings.sleepNow { [weak self] result in
            self?.sleepNowRunning = false
            Log.info(result.succeeded ? "pmset sleepnow done" : "pmset sleepnow failed: \(result.failureReason)")
        }
    }

    // MARK: Status

    private func writeStatus(stopped: Bool = false) {
        guard startedUp else { return }
        let snapshot = StatusSnapshot(
            state: engine.state,
            intent: engine.intent,
            lidClosed: lidClosed,
            internetReachable: internetReachable,
            thermal: thermal,
            temperatures: temperatures,
            power: power,
            sleepDisabled: RootDomain.sleepDisabled,
            lastError: engine.lastError,
            heartbeatAt: Date(),
            stoppedAt: stopped ? Date() : nil
        )
        do {
            try StateFiles.writeStatus(snapshot, runtime)
            reportedStatusWriteFailure = false
        } catch  where !reportedStatusWriteFailure {
            Log.info("cannot write \(runtime.statusURL.path(percentEncoded: false)): \(error)")
            reportedStatusWriteFailure = true
        } catch {}
    }

    // MARK: Termination

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            // The default action would kill the process before the dispatch source sees the signal.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.terminate(signal: signalNumber) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Restores normal sleep before exiting (design §8.3, A1). Runs synchronously and bounded, because
    /// launchd kills the process `ExitTimeOut` seconds after SIGTERM.
    private func terminate(signal signalNumber: Int32) {
        guard !terminating else { return }
        Log.info("received \(signalNumber == SIGTERM ? "SIGTERM" : "SIGINT"), restoring sleep before exit")
        let actions = engine.handle(.terminating, at: Date())
        terminating = true
        tickTimer?.invalidate()
        // A `sudo pmset` still running could land after the final restore and leave SleepDisabled at 1.
        if let note = SleepSettings.finishRunningCommands(
            grace: Self.terminationGrace, stopTimeout: Self.terminationStopTimeout)
        {
            Log.info(note)
        }
        for action in actions {
            switch action {
            case .setSleepDisabled(let disabled):
                Log.info("action: set SleepDisabled \(disabled ? 1 : 0)")
                let failure = SleepSettings.applySync(
                    disabled,
                    commandTimeout: Self.terminationCommandTimeout,
                    verifyTimeout: Self.terminationVerifyTimeout
                )
                Log.info(failure.map { "SleepDisabled change failed: \($0)" } ?? SleepSettings.appliedMessage(disabled))
            case .log(let message):
                Log.info("engine: \(message)")
            case .sleepNow, .turnDisplayOff, .notify:
                Log.info("terminating: skipped \(action)")
            }
        }
        // Marks the daemon as stopped, so `status` does not report it running for another 2 min.
        writeStatus(stopped: true)
        Log.info("daemon exiting")
        exit(0)
    }

    // MARK: Descriptions for the log

    private static func describe(_ event: Event) -> String {
        switch event {
        case .savedState(let state):
            "savedState(\(describe(state)))"
        case .startup(let intent, let sleepDisabled):
            "startup(intent \(intent.rawValue), SleepDisabled \(flag(sleepDisabled)))"
        case .intent(let intent):
            "intent(\(intent.rawValue))"
        case .lid(let closed):
            "lid(\(closed ? "closed" : "open"))"
        case .externalDisplay(let active):
            "externalDisplay(\(active ? "in use" : "none"))"
        case .probe(let reachable):
            "probe(\(reachable ? "reachable" : "unreachable"))"
        case .thermal(let reading):
            "thermal(\(reading.level), pressure \(reading.pressure))"
        case .temperatures(let reading):
            "temperatures(battery max \(celsius(reading.batteryMaxC)), chip average \(celsius(reading.dieAverageC)))"
        case .power(let reading):
            "power(\(reading.onBattery ? "battery" : "charger"), \(reading.percent.map { "\($0)%" } ?? "charge unknown"))"
        case .fullWake(let full):
            "fullWake(\(full))"
        case .tick(let sleepDisabled):
            "tick(SleepDisabled \(flag(sleepDisabled)))"
        case .applyFailed(let reason):
            "applyFailed(\(reason))"
        case .terminating:
            "terminating"
        }
    }

    private static func describe(_ state: ModeState) -> String {
        switch state {
        case .off: "off"
        case .active: "active"
        case .paused(let reasons): "paused(\(reasons.sorted().map(\.rawValue).joined(separator: ", ")))"
        }
    }

    private static func flag(_ value: Bool?) -> String {
        value.map { $0 ? "1" : "0" } ?? "unknown"
    }

    private static func celsius(_ value: Double?) -> String {
        value.map { String(format: "%.1f °C", $0) } ?? "unknown"
    }
}
