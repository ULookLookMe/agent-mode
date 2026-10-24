import Foundation

public struct InstallTargetError: Error, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// The executable path `agentmode install` writes into the LaunchAgent (F-002 design §3.2): the binary the
/// user ran, so any install location works, but never one that a build or an upgrade replaces.
public enum InstallTarget {
    public static func resolve(
        argv0: String,
        currentDirectory: String,
        pathVariable: String?,
        override: String?,
        isExecutableFile: (String) -> Bool
    ) -> Result<String, InstallTargetError> {
        if let override, !override.isEmpty {
            guard override.hasPrefix("/") else {
                return .failure(
                    InstallTargetError(message: "AGENTMODE_EXECUTABLE must be an absolute path, not '\(override)'"))
            }
            return .success(normalize(override))
        }

        let path: String
        if argv0.contains("/") {
            path = normalize(argv0.hasPrefix("/") ? argv0 : currentDirectory + "/" + argv0)
        } else {
            // Like the shell: relative entries count from the current directory, but empty entries are skipped
            // instead of standing for it.
            let directories = (pathVariable ?? "").split(separator: ":").map { entry in
                entry.hasPrefix("/") ? String(entry) : currentDirectory + "/" + entry
            }
            let candidates = directories.map { normalize($0 + "/" + argv0) }
            guard let found = candidates.first(where: isExecutableFile) else {
                return .failure(
                    InstallTargetError(
                        message:
                            "cannot find '\(argv0)' in PATH; run agentmode by its full path, or set AGENTMODE_EXECUTABLE to the path the LaunchAgent should run"
                    ))
            }
            path = found
        }

        let components = path.split(separator: "/")
        if components.contains(".build") {
            return .failure(
                InstallTargetError(
                    message:
                        "refusing to install \(path): the next build replaces it. Copy it first, for example 'install -m 0755 \(path) ~/.local/bin/agentmode', and run the copy, or set AGENTMODE_EXECUTABLE"
                ))
        }
        if components.contains("Cellar") {
            return .failure(
                InstallTargetError(
                    message:
                        "refusing to install \(path): it is inside Homebrew's Cellar, which changes with every upgrade. Run the linked path instead, for example '/opt/homebrew/bin/agentmode install'"
                ))
        }
        return .success(path)
    }

    /// Removes `.`, `..` and empty components of an absolute path without touching the filesystem, so
    /// symbolic links such as `/tmp` stay as written.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".":
                continue
            case "..":
                _ = parts.popLast()
            default:
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
