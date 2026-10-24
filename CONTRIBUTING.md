# Contributing to agentmode

Thanks for helping. Bug reports, reports of which Macs agentmode works on, and pull requests are all
welcome.

## Report how it works on your Mac

agentmode has been tested live on one MacBook Pro (M5, macOS 27.2). The most useful contribution right now
is a **Tested on my Mac** issue: it tells others which Macs read their temperature sensors and keep running
with the lid closed. Use the issue template and paste the output of `agentmode status`.

## Requirements

- An Apple silicon Mac with macOS 27 or later.
- Swift 6.4: Xcode 27, or only the Command Line Tools (`xcode-select --install`).

## Build, test and lint

```sh
swift build
swift test
swift format lint --strict --recursive Sources scripts Package.swift
swift build -c release -Xswiftc -warnings-as-errors
```

`Package.swift` adds the Command Line Tools' swift-testing plugin path, so `swift test` works without Xcode.

## Try it without touching your system

With `AGENTMODE_DRY_RUN=1`, agentmode runs no `sudo`, `pmset`, `osascript` or `launchctl`; it logs and
prints each action instead. It requires `AGENTMODE_STATE_DIR`, where it keeps every file:

```sh
export AGENTMODE_DRY_RUN=1 AGENTMODE_STATE_DIR="$(mktemp -d)"
.build/debug/agentmode daemon &   # prints the events and the actions it would take
.build/debug/agentmode on
.build/debug/agentmode status
kill %1                           # shows sleep being restored on exit
```

`install` refuses a binary inside `.build/`. To try it in a dry run, copy the binary elsewhere first or set
`AGENTMODE_EXECUTABLE`.

## How the code is organized

- `Sources/AgentModeCore`: the pure logic: the state machine (`Engine`), the CLI decisions, the status view
  and the configuration. Everything here has unit tests and no side effects.
- `Sources/agentmode`: the executable. It talks to macOS (power, lid, network, sensors, launchd) and feeds
  events into the engine.
- `Sources/CIOHIDPrivate`: declarations of the private temperature API, weak-linked.

[docs/architecture.md](docs/architecture.md) describes the states, the signals, the safety invariants and the
contract between the CLI and the background process.

## Pull requests

- Every behavior change starts with a test in `Tests/AgentModeCoreTests` that fails without the change.
- Keep the safety invariants in `docs/architecture.md`. In particular, `SleepDisabled` must never stay at 1
  after `agentmode off`.
- Run the four commands above before you push; CI runs them too.
- Write commit messages in English, in the [Conventional Commits](https://www.conventionalcommits.org) style
  (`fix: …`, `feat: …`, `docs: …`).
- Update `CHANGELOG.md` under **Unreleased**.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE) and that you
follow the [Code of Conduct](CODE_OF_CONDUCT.md).
