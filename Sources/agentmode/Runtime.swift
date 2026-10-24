import AgentModeCore
import Foundation

/// Where agentmode keeps its files and whether it may touch the system (plan "Restricciones globales").
///
/// With `AGENTMODE_DRY_RUN=1` every action is logged and printed instead of executed, and every file
/// lives under `AGENTMODE_STATE_DIR`, so a dry run never changes the system or the real state.
struct Runtime: Sendable {
    let dryRun: Bool
    let home: URL
    let uid: uid_t
    let stateDirectory: URL
    let logURL: URL
    let configURL: URL
    let launchAgentURL: URL
    /// The Darwin notification the CLI posts after writing the intent (plan "CLI ↔ daemon").
    let changeNotificationName: String

    var intentURL: URL { stateDirectory.appending(path: "intent.json") }
    var statusURL: URL { stateDirectory.appending(path: "status.json") }

    struct Error: Swift.Error {
        let message: String
    }

    /// Resolved once per process; `ProcessRunner` reads it to refuse commands during a dry run.
    static let current = Result { () throws(Error) -> Runtime in
        try Runtime(environment: ProcessInfo.processInfo.environment)
    }

    init(environment: [String: String]) throws(Error) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let uid = getuid()
        self.home = home
        self.uid = uid
        dryRun = environment["AGENTMODE_DRY_RUN"] == "1"
        let label = LaunchAgentPlist.label

        if dryRun {
            guard let path = environment["AGENTMODE_STATE_DIR"], !path.isEmpty else {
                throw Error(message: "AGENTMODE_DRY_RUN=1 requires AGENTMODE_STATE_DIR")
            }
            let directory = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
            stateDirectory = directory
            logURL = directory.appending(path: "agentmode.log")
            configURL = directory.appending(path: "config.json")
            launchAgentURL = directory.appending(path: "\(label).plist")
            // A separate name keeps a dry run from waking an installed daemon.
            changeNotificationName = "user.uid.\(uid).\(label).dryrun.changed"
        } else {
            stateDirectory = home.appending(path: "Library/Application Support/agentmode", directoryHint: .isDirectory)
            logURL = home.appending(path: "Library/Logs/agentmode.log")
            configURL = home.appending(path: ".config/agentmode/config.json")
            launchAgentURL = home.appending(path: "Library/LaunchAgents/\(label).plist")
            changeNotificationName = "user.uid.\(uid).\(label).changed"
        }
    }

    static var isDryRun: Bool {
        (try? current.get().dryRun) ?? true
    }
}
