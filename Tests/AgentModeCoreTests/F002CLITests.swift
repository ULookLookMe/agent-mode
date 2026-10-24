import Foundation
import Testing

@testable import AgentModeCore

// F-002 design §3.1: version, help and `status --json` in the CLI.
// Contract tests written from the spec and the public interfaces only.

@Suite struct F002CLITests {

    // MARK: - Version

    @Test("F-002 · E1 · the version is MAJOR.MINOR.PATCH with digits only")
    func versionIsMajorMinorPatch() {
        let version = AgentModeVersion.current
        #expect(version.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil, "got \(version)")
    }

    @Test("F-002 · E2 · the version line is `agentmode <version>`")
    func versionLineNamesTheVersion() {
        #expect(CommandParser.versionLine == "agentmode " + AgentModeVersion.current)
    }

    // MARK: - CommandParser

    @Test("F-002 · E3 · `--version` and `version` parse to .version", arguments: [["--version"], ["version"]])
    func parsesVersion(args: [String]) {
        #expect(CommandParser.parse(args) == .success(.version))
    }

    @Test("F-002 · E4 · `--help`, `-h` and `help` parse to .help", arguments: [["--help"], ["-h"], ["help"]])
    func parsesHelp(args: [String]) {
        #expect(CommandParser.parse(args) == .success(.help))
    }

    @Test("F-002 · E5 · `status --json` parses to .statusJSON")
    func parsesStatusJSON() {
        #expect(CommandParser.parse(["status", "--json"]) == .success(.statusJSON))
    }

    @Test(
        "F-002 · E6 · `status` followed by anything but `--json` is a usage error",
        arguments: [
            ["status", "--other"], ["status", "json"], ["status", "-j"], ["status", "--JSON"], ["status", ""],
        ]
    )
    func statusWithOtherArgumentIsUsageError(args: [String]) {
        #expect(throws: UsageError.self) {
            try CommandParser.parse(args).get()
        }
    }

    @Test(
        "F-002 · E7 · no arguments, unknown words and extra arguments stay usage errors",
        arguments: [
            [], ["fly"], ["--json"], ["-v"], ["on", "off"], ["status", "--json", "extra"],
            ["--version", "extra"], ["version", "--json"], ["help", "on"], ["-h", "status"],
        ] as [[String]]
    )
    func otherInputsStayUsageErrors(args: [String]) {
        #expect(throws: UsageError.self) {
            try CommandParser.parse(args).get()
        }
    }

    // MARK: - CLIPlanner

    @Test(
        "F-002 · E8 · version, help and status --json only print, whatever the intent and the daemon",
        arguments: [
            (Command.version, CLIAction.printVersion),
            (Command.help, CLIAction.printHelp),
            (Command.statusJSON, CLIAction.printStatusJSON),
        ]
    )
    func printCommandsOnlyPrint(command: Command, expected: CLIAction) {
        for intent in [Intent.off, .on] {
            for daemonAlive in [false, true] {
                #expect(
                    CLIPlanner.actions(for: command, currentIntent: intent, daemonAlive: daemonAlive) == [expected],
                    "intent \(intent), daemonAlive \(daemonAlive)"
                )
            }
        }
    }

    // MARK: - Help text and usage

    static let documentedCommands = [
        "on", "off", "toggle", "status", "status --json", "install", "uninstall", "daemon", "help", "version",
    ]

    /// Whether `line` documents `command`: after the indentation and an optional `agentmode `, the line starts
    /// with the command as a whole word and the same line carries a description (a word with letters that is
    /// not an option alias such as `--help`). `status` only counts when it is not `status --json`.
    static func line(_ line: String, describes command: String) -> Bool {
        var rest = Substring(line).drop(while: \.isWhitespace)
        if rest.hasPrefix("agentmode ") {
            rest = rest.dropFirst("agentmode ".count).drop(while: \.isWhitespace)
        }
        guard rest.hasPrefix(command) else { return false }
        rest = rest.dropFirst(command.count)
        guard let next = rest.first, next.isWhitespace || next == "," || next == ":" else { return false }
        let remainder = rest.drop(while: { $0.isWhitespace || $0 == "," || $0 == ":" })
        if command == "status" && remainder.hasPrefix("--json") { return false }
        let words = remainder.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        return words.contains { !$0.hasPrefix("-") && $0.contains(where: \.isLetter) }
    }

    @Test("F-002 · E9 · the help text spans several lines and describes every command on its own line")
    func helpTextDescribesEveryCommand() {
        let lines = CommandParser.helpText.split(separator: "\n").map(String.init)
        #expect(lines.count > 1, "help text: \(CommandParser.helpText)")
        for command in Self.documentedCommands {
            #expect(
                lines.contains { Self.line($0, describes: command) },
                "no line describes `\(command)` in:\n\(CommandParser.helpText)"
            )
        }
    }

    @Test(
        "F-002 · E10 · a usage error ends with the usage line, which mentions `agentmode help`",
        arguments: [[], ["fly"], ["status", "--other"], ["version", "extra"]] as [[String]]
    )
    func usageErrorEndsWithUsageLine(args: [String]) throws {
        guard case .failure(let error) = CommandParser.parse(args) else {
            Issue.record("expected a UsageError for \(args)")
            return
        }
        let lines = error.message.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        let last = try #require(lines.last, "empty usage error message")
        #expect(last.contains("agentmode help"), "message: \(error.message)")
    }
}
