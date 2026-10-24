import AgentModeCore
import Foundation
import notify

// agentmode on | off | toggle | status [--json] | daemon | install | uninstall | help | version
// (design §8.1, F-002 design §3).
// The decisions live in AgentModeCore (`CommandParser`, `CLIPlanner`); this file only executes them.

let usageExitCode: Int32 = 64

let command: Command
switch CommandParser.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed):
    command = parsed
case .failure(let usage):
    FileHandle.standardError.write(Data("agentmode: \(usage.message)\n".utf8))
    exit(usageExitCode)
}

let runtime: Runtime
switch Runtime.current {
case .success(let resolved):
    runtime = resolved
case .failure(let problem):
    FileHandle.standardError.write(Data("agentmode: \(problem.message)\n".utf8))
    exit(usageExitCode)
}

Log.configure(url: runtime.logURL, echo: runtime.dryRun)

let lastStatus = StateFiles.readStatus(runtime)
let daemonAlive = lastStatus?.isDaemonRunning(at: Date()) ?? false

let currentIntent: Intent
do {
    currentIntent = try StateFiles.readIntent(runtime)
} catch {
    Log.info("cli: cannot read \(runtime.intentURL.path(percentEncoded: false)), treating the mode as off: \(error)")
    currentIntent = .off
}

/// The daemon's last snapshot merged with the saved intent and the live kernel value.
func statusView() -> StatusView {
    StatusView.make(
        snapshot: lastStatus, intent: currentIntent, liveSleepDisabled: RootDomain.sleepDisabled, now: Date(),
        allowUnknownTemperatures: StateFiles.loadConfig(runtime).allowUnknownTemperatures)
}

/// The path the LaunchAgent will run: the binary the user invoked (F-002 design §3.2).
func installTarget() -> Result<String, InstallTargetError> {
    let environment = ProcessInfo.processInfo.environment
    return InstallTarget.resolve(
        argv0: CommandLine.arguments[0],
        currentDirectory: FileManager.default.currentDirectoryPath,
        pathVariable: environment["PATH"],
        override: environment["AGENTMODE_EXECUTABLE"],
        isExecutableFile: FileManager.default.isExecutableFile(atPath:)
    )
}

/// Restores or sets `SleepDisabled` from the CLI, for `off` while the daemon may be down. Skips the
/// privileged command when the kernel already has the value.
func setSleepDisabled(_ disabled: Bool) -> Bool {
    if RootDomain.sleepDisabled == disabled {
        Log.info("cli: SleepDisabled is already \(disabled ? 1 : 0)")
        return true
    }
    if let failure = SleepSettings.applySync(
        disabled, commandTimeout: SleepSettings.commandTimeout, verifyTimeout: SleepSettings.verifyTimeout)
    {
        CLIOutput.warn("could not set SleepDisabled to \(disabled ? 1 : 0): \(failure)")
        CLIOutput.sudoersHelp()
        return false
    }
    Log.info("cli: \(SleepSettings.appliedMessage(disabled))")
    if !disabled {
        sleepIfLidClosed()
    }
    return true
}

/// Clearing `disablesleep` with the lid closed does not sleep the Mac by itself (design §8.3), so when
/// this command is the one that cleared it, it also puts the Mac to sleep, unless an external display
/// is in use (A5). The daemon does the same for the changes it makes.
func sleepIfLidClosed() {
    guard RootDomain.lidClosed == true, !DisplayController.externalDisplayInUse() else { return }
    let result = ProcessRunner.run(SleepSettings.pmset, ["sleepnow"], timeout: SleepSettings.commandTimeout)
    Log.info(
        result.succeeded
            ? "cli: lid closed, pmset sleepnow done" : "cli: pmset sleepnow failed: \(result.failureReason)")
}

var exitCode: Int32 = 0
var newIntent: Intent?
for action in CLIPlanner.actions(for: command, currentIntent: currentIntent, daemonAlive: daemonAlive) {
    switch action {
    case .writeIntent(let intent):
        do {
            try StateFiles.writeIntent(intent, runtime)
            newIntent = intent
            Log.info(
                "cli: intent \(intent.rawValue) (was \(currentIntent.rawValue), daemon \(daemonAlive ? "running" : "not running"))"
            )
        } catch {
            CLIOutput.error(
                "cannot write \(runtime.intentURL.path(percentEncoded: false)): \(error.localizedDescription)")
            exit(1)
        }
    case .notifyDaemon:
        let status = notify_post(runtime.changeNotificationName)
        if status != NOTIFY_STATUS_OK {
            Log.info("cli: notify_post failed (\(status))")
        }
    case .setSleepDisabled(let disabled):
        if !setSleepDisabled(disabled) {
            exitCode = 1
        }
    case .printStatus:
        print(statusView().text())
    case .printStatusJSON:
        print(statusView().json())
    case .printVersion:
        print(CommandParser.versionLine)
    case .printHelp:
        print(CommandParser.helpText)
    case .runDaemon:
        Daemon(runtime: runtime).run()
    case .installAgent:
        switch installTarget() {
        case .success(let path):
            exitCode = LaunchAgentInstaller.install(runtime, executable: URL(filePath: path))
        case .failure(let problem):
            CLIOutput.error(problem.message)
            exitCode = 1
        }
    case .uninstallAgent:
        exitCode = LaunchAgentInstaller.uninstall(runtime)
    }
}

if let newIntent {
    CLIOutput.say("agentmode: \(newIntent.rawValue)")
    if newIntent == .on && !daemonAlive {
        CLIOutput.warn("the daemon is not running, so nothing changes until it starts (agentmode install)")
    }
    if newIntent == .on && daemonAlive {
        // With the daemon running, the only warnings are about heat protection (F-002 design §3.3).
        for warning in statusView().warnings {
            CLIOutput.warn(warning)
        }
    }
}
exit(exitCode)
