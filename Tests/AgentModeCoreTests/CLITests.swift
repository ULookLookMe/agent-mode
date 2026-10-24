import Foundation
import Testing

@testable import AgentModeCore

/// Contract for the pure CLI layer (design.md §8.1, §8.2; plan Tarea 3 and Tarea R).
/// `CommandParser.parse` receives the arguments after the executable name.
@Suite
struct CLITests {

    // MARK: - CommandParser

    @Test(arguments: [
        ("on", Command.on),
        ("off", Command.off),
        ("toggle", Command.toggle),
        ("status", Command.status),
        ("daemon", Command.daemon),
        ("install", Command.install),
        ("uninstall", Command.uninstall),
    ])
    func parsesKnownCommands(word: String, expected: Command) {
        #expect(CommandParser.parse([word]) == .success(expected))
    }

    @Test
    func unknownCommandIsUsageError() {
        #expect(throws: UsageError.self) {
            try CommandParser.parse(["fly"]).get()
        }
    }

    // MARK: - CLIPlanner

    @Test(arguments: [true, false])
    func toggleFollowsIntent(daemonAlive: Bool) {
        #expect(
            CLIPlanner.actions(for: .toggle, currentIntent: .off, daemonAlive: daemonAlive)
                == [.writeIntent(.on), .notifyDaemon]
        )
        #expect(
            CLIPlanner.actions(for: .toggle, currentIntent: .on, daemonAlive: daemonAlive)
                == [.writeIntent(.off), .notifyDaemon, .setSleepDisabled(false)]
        )
    }

    @Test
    func offAppliesDirectlyWhenDaemonIsDown() {
        let actions = CLIPlanner.actions(for: .off, currentIntent: .on, daemonAlive: false)
        #expect(actions.contains(.setSleepDisabled(false)))
    }

    @Test(arguments: [Intent.off, Intent.on], [true, false])
    func onWritesIntentAndNotifiesDaemon(currentIntent: Intent, daemonAlive: Bool) {
        #expect(
            CLIPlanner.actions(for: .on, currentIntent: currentIntent, daemonAlive: daemonAlive)
                == [.writeIntent(.on), .notifyDaemon]
        )
    }

    @Test(arguments: [Intent.off, Intent.on], [true, false])
    func offAlwaysRestoresSleep(currentIntent: Intent, daemonAlive: Bool) {
        #expect(
            CLIPlanner.actions(for: .off, currentIntent: currentIntent, daemonAlive: daemonAlive)
                == [.writeIntent(.off), .notifyDaemon, .setSleepDisabled(false)]
        )
    }

    @Test(arguments: [Intent.off, Intent.on], [true, false])
    func statusOnlyPrintsStatus(currentIntent: Intent, daemonAlive: Bool) {
        #expect(
            CLIPlanner.actions(for: .status, currentIntent: currentIntent, daemonAlive: daemonAlive)
                == [.printStatus]
        )
    }
}
