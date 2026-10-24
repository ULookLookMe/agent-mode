import AgentModeCore
import Foundation

/// `agentmode install` and `agentmode uninstall` (design §8.1, §8.6): the user LaunchAgent that keeps
/// `agentmode daemon` running in the user's GUI session. No root is needed.
enum LaunchAgentInstaller {
    static let launchctl = "/bin/launchctl"

    /// Writes the plist that runs `executable`, reloads the agent and warns when the sudoers rule is missing.
    /// Returns the exit code.
    static func install(_ runtime: Runtime, executable: URL) -> Int32 {
        let plistPath = runtime.launchAgentURL.path(percentEncoded: false)
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: LaunchAgentPlist.make(home: runtime.home, executable: executable),
                format: .xml,
                options: 0
            )
            try StateFiles.writeAtomically(data, to: runtime.launchAgentURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistPath)
        } catch {
            CLIOutput.error("cannot write \(plistPath): \(error.localizedDescription)")
            return 1
        }
        Log.info("install: wrote \(plistPath)")
        if runtime.dryRun {
            CLIOutput.say("dry run: the plist went to \(plistPath) instead of ~/Library/LaunchAgents")
        }

        let executablePath = executable.path(percentEncoded: false)
        Log.info("install: the agent runs \(executablePath)")
        if !FileManager.default.isExecutableFile(atPath: executablePath) {
            CLIOutput.warn("\(executablePath) is not an executable file yet; the agent starts once it is there")
        }

        bootOut(runtime)
        guard bootstrap(runtime, plistPath: plistPath) else {
            return 1
        }
        CLIOutput.say(
            runtime.dryRun
                ? "agentmode: dry run, nothing was loaded" : "agentmode: LaunchAgent \(LaunchAgentPlist.label) loaded")

        // Both commands: a rule that allows only `1` would let the mode start but never restore sleep (A1).
        // `-k` ignores a cached sudo session, which the daemon will not have, without discarding it.
        var ruleMissing = false
        for disabled in [false, true] {
            let command = Array(SleepSettings.arguments(disabled).dropFirst())
            let check = ProcessRunner.run(SleepSettings.sudo, ["-k", "-n", "-l"] + command, timeout: 10)
            if !check.succeeded {
                CLIOutput.warn(
                    "sudo cannot run '\(command.joined(separator: " "))' without a password (\(check.failureReason))")
                ruleMissing = true
            }
        }
        if ruleMissing {
            CLIOutput.sudoersHelp()
        }
        return 0
    }

    /// Unloads the agent, makes sure `SleepDisabled` is 0 (A1) and removes the plist. Returns the exit code.
    static func uninstall(_ runtime: Runtime) -> Int32 {
        var exitCode: Int32 = 0
        // Booting out sends the daemon SIGTERM; it restores sleep itself before exiting.
        bootOut(runtime)

        if RootDomain.sleepDisabled != false {
            if let failure = SleepSettings.applySync(
                false, commandTimeout: SleepSettings.commandTimeout, verifyTimeout: SleepSettings.verifyTimeout)
            {
                CLIOutput.warn("could not set SleepDisabled to 0: \(failure)")
                CLIOutput.sudoersHelp()
                exitCode = 1
            } else {
                Log.info("uninstall: \(SleepSettings.appliedMessage(false))")
            }
        }

        let plistPath = runtime.launchAgentURL.path(percentEncoded: false)
        do {
            try FileManager.default.removeItem(at: runtime.launchAgentURL)
            Log.info("uninstall: removed \(plistPath)")
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        } catch {
            CLIOutput.error("cannot remove \(plistPath): \(error.localizedDescription)")
            exitCode = 1
        }
        if exitCode == 0 {
            CLIOutput.say(
                runtime.dryRun
                    ? "agentmode: dry run, nothing was unloaded" : "agentmode: LaunchAgent removed; SleepDisabled is 0")
        }
        return exitCode
    }

    private static func domain(_ runtime: Runtime) -> String {
        "gui/\(runtime.uid)"
    }

    /// Unloads the agent if it is loaded; "not loaded" is not an error.
    private static func bootOut(_ runtime: Runtime) {
        let result = ProcessRunner.run(
            launchctl, ["bootout", "\(domain(runtime))/\(LaunchAgentPlist.label)"], timeout: 20)
        if result.succeeded {
            Log.info("launchctl bootout done")
        } else if isNotLoaded(result) {
            Log.info("launchctl bootout: agent was not loaded")
        } else {
            CLIOutput.warn("launchctl bootout failed: \(result.failureReason)")
        }
    }

    /// Loads the agent, retrying briefly: right after a bootout launchd can still be tearing it down.
    private static func bootstrap(_ runtime: Runtime, plistPath: String) -> Bool {
        var last = ProcessResult(status: -1, stdout: "", stderr: "")
        for attempt in 1...3 {
            last = ProcessRunner.run(launchctl, ["bootstrap", domain(runtime), plistPath], timeout: 20)
            if last.succeeded {
                Log.info("launchctl bootstrap done (attempt \(attempt))")
                return true
            }
            sleep(1)
        }
        CLIOutput.error("launchctl bootstrap failed: \(last.failureReason)")
        return false
    }

    private static func isNotLoaded(_ result: ProcessResult) -> Bool {
        // launchctl reports a missing service as ESRCH (3) or as "Could not find service" (113).
        let text = (result.stderr + result.stdout).lowercased()
        return result.status == 3 || result.status == 113 || text.contains("no such process")
            || text.contains("could not find")
    }
}

/// Messages the CLI prints for the user.
enum CLIOutput {
    static func say(_ message: String) {
        print(message)
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("agentmode: warning: \(message)\n".utf8))
        Log.info("cli warning: \(message)")
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data("agentmode: error: \(message)\n".utf8))
        Log.info("cli error: \(message)")
    }

    /// Names the exact rule the privileged command needs (design §7).
    static func sudoersHelp() {
        let help = """
            agentmode: the sudoers rule for pmset is missing or does not match. Create it with
              sudo visudo -f /etc/sudoers.d/agentmode
            containing exactly this line:
              \(SleepSettings.sudoersRule)

            """
        FileHandle.standardError.write(Data(help.utf8))
    }
}
