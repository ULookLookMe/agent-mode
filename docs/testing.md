# Testing

## Unit tests

`swift test` runs the unit tests of `AgentModeCore`: the state machine (pauses, resumes, full-wake rules,
self-heal, restarts), the CLI decisions, the status view, the notification texts, the configuration and
the install-path rules. They use an injected clock and never touch the system, so they run anywhere,
including CI.

The tests are written from the specification before the code, and each bug fix starts with a test that
fails on the old code.

## Live acceptance tests

These run on a real Mac and need a person. Results so far are on **one MacBook Pro (M5, macOS 27.2)**,
16 October 2026.

| ID | Scenario | Passes if | Result |
|---|---|---|---|
| Install | `setup-privileges.sh` and `agentmode install` | The service runs; the rule is `0440 root:wheel`; both commands run without a password; at startup `SleepDisabled` goes 1 → 0 with the mode off | Pass (28 ms) |
| AC1 | Mode on, lid closed 60 s | No `Sleep` in `pmset -g log`; the display-off signature within 3 s; keyboard backlight suppressed | Pass (display off in ~1.6 s; repeated for 2 min 25 s) |
| AC2 | `agentmode off` with the lid closed | The Mac sleeps within 30 s | Pass (11 s) |
| AC3 | Wi-Fi off with the lid open, `internetTimeoutMinutes` = 2 | Pauses within 3 min and resumes when the network returns | **Pending** (unit-tested) |
| AC4 | `SleepDisabled` set to 0 from outside with the mode on | Back to 1 within 60 s | Pass (22 s) |
| AC5 | Log out and log back in | Mode on: `SleepDisabled` = 1 with no action; mode off: 0 | **Pending** (unit-tested) |
| AC6 | On battery with `batteryFloorPercent` above the current charge | Pauses; connecting the charger with the lid open resumes | Pass (resumed in 52 ms) |
| AC7 | Pause with the lid closed, connect the charger without opening the lid, wait 30 min | The Mac keeps sleeping apart from maintenance wakes, `SleepDisabled` stays 0, the mode stays paused; opening the lid resumes | **Pending** (unit-tested) |
| AC8 | External display in use when the lid closes | The external display stays on | **Pending** (needs a monitor) |

"Unit-tested" means the behavior is covered by unit tests but has not been checked live yet.

## Smoke test without touching the system

CI runs every command in dry-run mode (`AGENTMODE_DRY_RUN=1`), which logs actions instead of running
`sudo`, `pmset`, `osascript` or `launchctl`. See [CONTRIBUTING.md](../CONTRIBUTING.md) to run it yourself.
