import Foundation

public enum Command: Equatable, Sendable {
    case on, off, toggle, status, daemon, install, uninstall
    case version, help, statusJSON
}

public struct UsageError: Error, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum CLIAction: Equatable, Sendable {
    case writeIntent(Intent)
    case notifyDaemon
    case setSleepDisabled(Bool)
    case printStatus, runDaemon, installAgent,
        uninstallAgent
    case printVersion, printHelp, printStatusJSON
}

public enum CommandParser {
    /// Ordered so the usage line lists the commands in the same order as the design. Aliases follow the word.
    private static let commands: [(words: [String], command: Command)] = [
        (["on"], .on),
        (["off"], .off),
        (["toggle"], .toggle),
        (["status"], .status),
        (["daemon"], .daemon),
        (["install"], .install),
        (["uninstall"], .uninstall),
        (["help", "--help", "-h"], .help),
        (["version", "--version"], .version),
    ]

    static let usage =
        "usage: agentmode on | off | toggle | status [--json] | daemon | install | uninstall | help | version"
        + " (see 'agentmode help')"

    public static let versionLine = "agentmode " + AgentModeVersion.current

    public static let helpText = """
        agentmode \(AgentModeVersion.current): keeps this Mac awake for coding agents, lid open or closed,
        and pauses on its own when that stops being useful or safe.

        usage: agentmode <command>

          on              turn the mode on
          off             turn the mode off and restore normal sleep
          toggle          switch between on and off
          status          show the mode, the readings and the background process
          status --json   the same as JSON, for scripts and apps
          install         install or restart the background process (a LaunchAgent)
          uninstall       remove the background process and restore normal sleep
          daemon          run the background process (launchd starts it for you)
          help            show this help (also -h, --help)
          version         show the version (also --version)

        Docs: https://github.com/ULookLookMe/agent-mode
        """

    /// `args` are the arguments after the executable name.
    public static func parse(_ args: [String]) -> Result<Command, UsageError> {
        guard let word = args.first else {
            return .failure(usageError("missing command"))
        }
        if word == "status" && args.count == 2 {
            return args[1] == "--json"
                ? .success(.statusJSON) : .failure(usageError("unknown option '\(args[1])' for 'status'"))
        }
        guard let command = commands.first(where: { $0.words.contains(word) })?.command else {
            return .failure(usageError("unknown command '\(word)'"))
        }
        guard args.count == 1 else {
            return .failure(usageError("unexpected arguments after '\(word)'"))
        }
        return .success(command)
    }

    private static func usageError(_ problem: String) -> UsageError {
        UsageError(message: "\(problem)\n\(usage)")
    }
}

public enum CLIPlanner {
    public static func actions(for command: Command, currentIntent: Intent, daemonAlive: Bool) -> [CLIAction] {
        switch command {
        case .on:
            [.writeIntent(.on), .notifyDaemon]
        case .off:
            // Restored even when the daemon looks alive: its heartbeat can be stale after a SIGKILL, and
            // `SleepDisabled` must never stay at 1 after `off` (design A1). A second apply is harmless.
            [.writeIntent(.off), .notifyDaemon, .setSleepDisabled(false)]
        case .toggle:
            actions(for: currentIntent == .on ? .off : .on, currentIntent: currentIntent, daemonAlive: daemonAlive)
        case .status:
            [.printStatus]
        case .daemon:
            [.runDaemon]
        case .install:
            [.installAgent]
        case .uninstall:
            [.uninstallAgent]
        case .version:
            [.printVersion]
        case .help:
            [.printHelp]
        case .statusJSON:
            [.printStatusJSON]
        }
    }
}

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public var state: ModeState
    public var intent: Intent
    public var lidClosed: Bool?
    public var internetReachable: Bool?
    public var thermal: ThermalReading?
    public var temperatures: TemperatureReading?
    public var power: PowerReading?
    public var sleepDisabled: Bool?
    public var lastError: String?
    public var heartbeatAt: Date
    /// Set by the daemon as it exits; `nil` while it runs.
    public var stoppedAt: Date?

    /// The daemon refreshes `heartbeatAt` at least every minute, so an older one means it is gone.
    public static let heartbeatLimit: TimeInterval = 120

    public init(
        state: ModeState,
        intent: Intent,
        lidClosed: Bool?,
        internetReachable: Bool?,
        thermal: ThermalReading?,
        temperatures: TemperatureReading?,
        power: PowerReading?,
        sleepDisabled: Bool?,
        lastError: String?,
        heartbeatAt: Date,
        stoppedAt: Date? = nil
    ) {
        self.state = state
        self.intent = intent
        self.lidClosed = lidClosed
        self.internetReachable = internetReachable
        self.thermal = thermal
        self.temperatures = temperatures
        self.power = power
        self.sleepDisabled = sleepDisabled
        self.lastError = lastError
        self.heartbeatAt = heartbeatAt
        self.stoppedAt = stoppedAt
    }

    /// Whether the daemon that wrote this snapshot is still running at `now`.
    public func isDaemonRunning(at now: Date) -> Bool {
        stoppedAt == nil && now.timeIntervalSince(heartbeatAt) < Self.heartbeatLimit
    }
}

public enum StatusFormatter {
    private static let unknown = "unknown"
    /// Names of `com.apple.system.thermalpressurelevel` values 0...4.
    private static let pressureNames = ["nominal", "moderate", "heavy", "trapping", "sleeping"]

    public static func render(_ s: StatusSnapshot) -> String {
        [
            "Mode: \(mode(s.state))",
            "Intent: \(s.intent.rawValue)",
            "SleepDisabled: \(s.sleepDisabled.map { $0 ? "1" : "0" } ?? unknown)",
            "Lid: \(s.lidClosed.map { $0 ? "closed" : "open" } ?? unknown)",
            "Internet: \(s.internetReachable.map { $0 ? "reachable" : "unreachable" } ?? unknown)",
            "Thermal: \(s.thermal.map(thermal) ?? unknown)",
            "Battery temperature (max): \(celsius(s.temperatures?.batteryMaxC))",
            "Chip temperature (average): \(celsius(s.temperatures?.dieAverageC))",
            "Power: \(s.power.map(power) ?? unknown)",
            "Last error: \(s.lastError ?? "none")",
            "Heartbeat: \(s.heartbeatAt.formatted(.iso8601))",
        ].joined(separator: "\n")
    }

    private static func mode(_ state: ModeState) -> String {
        switch state {
        case .off:
            "off"
        case .active:
            "active"
        case .paused(let reasons) where reasons.isEmpty:
            "paused (waiting for full wake)"
        case .paused(let reasons):
            // Declaration order follows the design's P1, P2, P3 numbering.
            "paused (\(PauseReason.allCases.filter(reasons.contains).map(name).joined(separator: ", ")))"
        }
    }

    private static func name(_ reason: PauseReason) -> String {
        switch reason {
        case .noInternet: "no internet"
        case .thermal: "heat"
        case .lowBattery: "low battery"
        case .sensorsUnavailable: "sensors unreadable"
        }
    }

    private static func thermal(_ r: ThermalReading) -> String {
        let pressure = r.pressure < pressureNames.count ? pressureNames[Int(r.pressure)] : "level \(r.pressure)"
        return "\(r.level), pressure \(pressure)"
    }

    private static func power(_ p: PowerReading) -> String {
        "\(p.onBattery ? "battery" : "charger"), \(p.percent.map { "\($0)%" } ?? "charge \(unknown)")"
    }

    /// `String(format:)` ignores the user's locale, so the decimal separator is always a dot.
    private static func celsius(_ value: Double?) -> String {
        value.map { String(format: "%.1f °C", $0) } ?? unknown
    }
}

public enum LaunchAgentPlist {
    public static let label = "com.jsanchez.agentmode"

    /// The plist for the binary at `~/.local/bin/agentmode`.
    public static func make(home: URL) -> [String: Any] {
        make(home: home, executable: home.appending(path: ".local/bin/agentmode"))
    }

    /// The plist that runs `executable daemon` (F-002 design §3.2).
    public static func make(home: URL, executable: URL) -> [String: Any] {
        func path(_ relative: String) -> String {
            home.appending(path: relative).path(percentEncoded: false)
        }
        // launchd's stdout/stderr get their own files: the daemon rotates `agentmode.log` itself, and launchd
        // would keep appending to the rotated file through the descriptor it holds open.
        return [
            "Label": label,
            "ProgramArguments": [executable.path(percentEncoded: false), "daemon"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ExitTimeOut": 10,
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": path("Library/Logs/agentmode.stdout.log"),
            "StandardErrorPath": path("Library/Logs/agentmode.stderr.log"),
        ]
    }
}
