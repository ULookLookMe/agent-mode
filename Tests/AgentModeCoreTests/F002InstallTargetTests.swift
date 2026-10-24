import Foundation
import Testing

@testable import AgentModeCore

// F-002 design §3.2: the executable path `agentmode install` writes into the LaunchAgent.
// Contract tests written from the spec and the public interfaces only. `isExecutableFile` is always a fake
// backed by a set of paths, so no test reads the real filesystem.

/// One call to `InstallTarget.resolve` with fictitious inputs.
struct F002Invocation: Sendable, CustomTestStringConvertible {
    var argv0: String
    var cwd = "/Users/tester"
    var path: String? = nil
    var override: String? = nil
    var executables: Set<String> = []

    var testDescription: String {
        "argv0=\(argv0) cwd=\(cwd) PATH=\(path ?? "nil") override=\(override ?? "nil")"
    }

    func resolve() -> Result<String, InstallTargetError> {
        InstallTarget.resolve(
            argv0: argv0,
            currentDirectory: cwd,
            pathVariable: path,
            override: override,
            isExecutableFile: { executables.contains($0) }
        )
    }
}

private func failureMessage(_ result: Result<String, InstallTargetError>) -> String? {
    guard case .failure(let error) = result else { return nil }
    return error.message
}

@Suite struct F002InstallTargetTests {
    static let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    // MARK: - LaunchAgentPlist

    @Test(
        "F-002 · E11 · the plist runs the given executable and is otherwise the default plist",
        arguments: ["/opt/homebrew/bin/agentmode", "/Users/tester/Agent Tools/agentmode"]
    )
    func plistRunsGivenExecutable(executablePath: String) {
        let plist = LaunchAgentPlist.make(home: Self.home, executable: URL(filePath: executablePath))
        #expect(plist["ProgramArguments"] as? [String] == [executablePath, "daemon"])

        var rest = plist
        rest["ProgramArguments"] = nil
        var reference = LaunchAgentPlist.make(home: Self.home)
        reference["ProgramArguments"] = nil
        #expect(NSDictionary(dictionary: rest).isEqual(to: reference))
    }

    @Test("F-002 · E12 · make(home:) equals make(home:executable:) with ~/.local/bin/agentmode")
    func defaultPlistUsesLocalBin() {
        let local = Self.home.appending(path: ".local/bin/agentmode")
        let withExecutable = LaunchAgentPlist.make(home: Self.home, executable: local)
        #expect(NSDictionary(dictionary: LaunchAgentPlist.make(home: Self.home)).isEqual(to: withExecutable))
    }

    // MARK: - Rule 1: AGENTMODE_EXECUTABLE

    @Test(
        "F-002 · E13 · an absolute override wins, normalized, and no other rule applies",
        arguments: [
            ("/opt/tools/agentmode", "/Users/tester/bin/agentmode", "/opt/tools/agentmode"),
            ("/opt/tools/agentmode", "agentmode", "/opt/tools/agentmode"),
            ("/opt//tools/./bin/../agentmode", "agentmode", "/opt/tools/agentmode"),
            (
                "/Users/tester/src/agent-mode/.build/release/agentmode", ".build/release/agentmode",
                "/Users/tester/src/agent-mode/.build/release/agentmode"
            ),
            (
                "/opt/homebrew/Cellar/agentmode/0.1.0/bin/agentmode", "agentmode",
                "/opt/homebrew/Cellar/agentmode/0.1.0/bin/agentmode"
            ),
        ]
    )
    func absoluteOverrideWins(override: String, argv0: String, expected: String) {
        let invocation = F002Invocation(
            argv0: argv0, path: "/fake/a", override: override, executables: ["/fake/a/agentmode"])
        #expect(invocation.resolve() == .success(expected))
    }

    @Test(
        "F-002 · E14 · a relative override fails naming AGENTMODE_EXECUTABLE, without falling back",
        arguments: ["agentmode", "bin/agentmode", "./agentmode", "../agentmode"]
    )
    func relativeOverrideFails(override: String) throws {
        let invocation = F002Invocation(
            argv0: "/usr/local/bin/agentmode", path: "/usr/local/bin", override: override,
            executables: ["/usr/local/bin/agentmode"])
        let result = invocation.resolve()
        let message = try #require(failureMessage(result), "expected a failure, got \(result)")
        #expect(message.contains("AGENTMODE_EXECUTABLE"), "message: \(message)")
    }

    @Test("F-002 · E15 · an empty or absent override falls through to argv0", arguments: [nil, ""] as [String?])
    func emptyOverrideIsIgnored(override: String?) {
        let invocation = F002Invocation(argv0: "/usr/local/bin/agentmode", override: override)
        #expect(invocation.resolve() == .success("/usr/local/bin/agentmode"))
    }

    // MARK: - Rule 2: argv0 with a slash

    @Test(
        "F-002 · E16 · argv0 with a slash is made absolute from the current directory and normalized",
        arguments: [
            ("./agentmode", "/Users/tester/tools", "/Users/tester/tools/agentmode"),
            ("./agentmode", "/Users/tester/tools/", "/Users/tester/tools/agentmode"),
            ("bin/agentmode", "/Users/tester/tools", "/Users/tester/tools/bin/agentmode"),
            ("bin/../bin/./agentmode", "/Users/tester/tools", "/Users/tester/tools/bin/agentmode"),
            ("../shared//agentmode", "/Users/tester/tools", "/Users/tester/shared/agentmode"),
            ("/usr/local//bin/./agentmode", "/Users/tester", "/usr/local/bin/agentmode"),
            ("/usr/local/sbin/../bin/agentmode", "/Users/tester", "/usr/local/bin/agentmode"),
        ]
    )
    func slashArgv0IsNormalized(argv0: String, cwd: String, expected: String) {
        // PATH holds another executable: a path with a slash must not be looked up in PATH.
        let invocation = F002Invocation(
            argv0: argv0, cwd: cwd, path: "/fake/a", executables: ["/fake/a/agentmode", expected])
        #expect(invocation.resolve() == .success(expected))
    }

    /// `/tmp` and `/var` are symbolic links to `/private/tmp` and `/private/var` on macOS, so an
    /// implementation that resolved links would answer with a `/private/...` path.
    @Test(
        "F-002 · E17 · normalization is lexical and never resolves symbolic links",
        arguments: [
            ("/tmp/agentmode", "/Users/tester", "/tmp/agentmode"),
            ("./agentmode", "/tmp", "/tmp/agentmode"),
            ("../agentmode", "/tmp/work", "/tmp/agentmode"),
            ("/var/tmp/agentmode", "/Users/tester", "/var/tmp/agentmode"),
            ("/tmp/../usr/local/bin/agentmode", "/Users/tester", "/usr/local/bin/agentmode"),
        ]
    )
    func normalizationKeepsSymlinks(argv0: String, cwd: String, expected: String) {
        let invocation = F002Invocation(argv0: argv0, cwd: cwd, executables: [expected])
        #expect(invocation.resolve() == .success(expected))
    }

    // MARK: - Rule 3: PATH search

    @Test(
        "F-002 · E18 · a bare argv0 takes the first PATH entry where it is executable",
        arguments: [
            ("/fake/a:/fake/b:/fake/c", ["/fake/b/agentmode", "/fake/c/agentmode"], "/fake/b/agentmode"),
            ("/fake/a:/fake/b:/fake/c", ["/fake/a/agentmode", "/fake/c/agentmode"], "/fake/a/agentmode"),
            (
                "/fake/c:/fake/b:/fake/a", ["/fake/a/agentmode", "/fake/b/agentmode", "/fake/c/agentmode"],
                "/fake/c/agentmode"
            ),
        ] as [(String, Set<String>, String)]
    )
    func pathSearchTakesFirstMatch(path: String, executables: Set<String>, expected: String) {
        let invocation = F002Invocation(argv0: "agentmode", path: path, executables: executables)
        #expect(invocation.resolve() == .success(expected))
    }

    @Test(
        "F-002 · E19 · empty PATH entries are skipped, never read as the current directory",
        arguments: [":/fake/b", "::/fake/b:", ":::/fake/b"]
    )
    func emptyPathEntriesAreSkipped(path: String) {
        let invocation = F002Invocation(
            argv0: "agentmode", cwd: "/Users/tester/work", path: path,
            executables: [
                "agentmode", "./agentmode", "/agentmode", "/Users/tester/work/agentmode", "/fake/b/agentmode",
            ])
        #expect(invocation.resolve() == .success("/fake/b/agentmode"))
    }

    @Test(
        "F-002 · E20 · a bare argv0 not found in PATH fails naming AGENTMODE_EXECUTABLE",
        arguments: [nil, "", ":::", "/fake/a:/fake/b"] as [String?]
    )
    func pathSearchWithoutMatchFails(path: String?) throws {
        // Only the current directory and the filesystem root hold an executable: neither is in PATH.
        let invocation = F002Invocation(
            argv0: "agentmode", cwd: "/Users/tester/work", path: path,
            executables: ["agentmode", "/agentmode", "/Users/tester/work/agentmode"])
        let result = invocation.resolve()
        let message = try #require(failureMessage(result), "expected a failure, got \(result)")
        #expect(message.contains("AGENTMODE_EXECUTABLE"), "message: \(message)")
    }

    // MARK: - Rule 4: build products and Homebrew's Cellar

    @Test(
        "F-002 · E21 · a path with a `.build` component fails pointing to install -m 0755 and AGENTMODE_EXECUTABLE",
        arguments: [
            F002Invocation(argv0: ".build/release/agentmode", cwd: "/Users/tester/src/agent-mode"),
            F002Invocation(argv0: "/Users/tester/src/agent-mode/.build/arm64-apple-macosx/debug/agentmode"),
            F002Invocation(
                argv0: "agentmode", path: "/fake/a:/Users/tester/src/agent-mode/.build/release",
                executables: ["/Users/tester/src/agent-mode/.build/release/agentmode"]),
        ]
    )
    func buildProductIsRejected(invocation: F002Invocation) throws {
        let result = invocation.resolve()
        let message = try #require(failureMessage(result), "expected a failure, got \(result)")
        #expect(message.contains("install -m 0755"), "message: \(message)")
        #expect(message.contains("AGENTMODE_EXECUTABLE"), "message: \(message)")
    }

    @Test(
        "F-002 · E22 · a path with a `Cellar` component fails pointing to /opt/homebrew/bin/agentmode",
        arguments: [
            F002Invocation(argv0: "/opt/homebrew/Cellar/agentmode/0.1.0/bin/agentmode"),
            F002Invocation(argv0: "../Cellar/agentmode/0.1.0/bin/agentmode", cwd: "/opt/homebrew/bin"),
            F002Invocation(
                argv0: "agentmode", path: "/opt/homebrew/Cellar/agentmode/0.1.0/bin",
                executables: ["/opt/homebrew/Cellar/agentmode/0.1.0/bin/agentmode"]),
        ]
    )
    func cellarPathIsRejected(invocation: F002Invocation) throws {
        let result = invocation.resolve()
        let message = try #require(failureMessage(result), "expected a failure, got \(result)")
        #expect(message.contains("Cellar"), "message: \(message)")
        #expect(message.contains("/opt/homebrew/bin/agentmode"), "message: \(message)")
    }

    @Test(
        "F-002 · E23 · only whole `.build` or `Cellar` components of the normalized path are rejected",
        arguments: [
            ("/Users/tester/.buildtools/agentmode", "/Users/tester/.buildtools/agentmode"),
            ("/Users/tester/my.build/agentmode", "/Users/tester/my.build/agentmode"),
            ("/opt/Cellarium/bin/agentmode", "/opt/Cellarium/bin/agentmode"),
            ("/Users/tester/src/.build/../bin/agentmode", "/Users/tester/src/bin/agentmode"),
            ("/opt/homebrew/Cellar/../bin/agentmode", "/opt/homebrew/bin/agentmode"),
        ]
    )
    func lookAlikeComponentsAreAccepted(argv0: String, expected: String) {
        let invocation = F002Invocation(argv0: argv0, executables: [expected])
        #expect(invocation.resolve() == .success(expected))
    }
}
