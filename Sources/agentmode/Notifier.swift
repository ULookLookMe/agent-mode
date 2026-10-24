import AgentModeCore
import Foundation

/// System notifications (design G7) through `osascript`. The message goes to the script as an argv
/// item, never into the AppleScript source, so no text can change what the script does.
enum Notifier {
    static func post(_ notice: Notice) {
        let message = text(for: notice)
        let arguments = [
            "-e", "on run argv",
            "-e", "display notification (item 1 of argv) with title \"agentmode\"",
            "-e", "end run",
            message,
        ]
        ProcessRunner.runAsync("/usr/bin/osascript", arguments, timeout: 10) { result in
            if !result.succeeded {
                Log.info("notification failed: \(result.failureReason)")
            }
        }
    }

    /// In the user's first macOS language when it is Spanish, else in English (F-002 design §3.4).
    static func text(for notice: Notice) -> String {
        NoticeText.text(for: notice, preferredLanguages: Locale.preferredLanguages)
    }
}
