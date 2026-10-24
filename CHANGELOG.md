# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - Unreleased

First public release.

### Added

- `agentmode on | off | toggle | status | install | uninstall`: keeps an Apple silicon MacBook awake with the
  lid open or closed (`pmset -a disablesleep 1`) and turns the internal display off when the lid closes.
- Automatic pauses: 10 minutes without internet; heat (battery at 40 °C or more, chip average at 80 °C or more
  for 5 minutes, or macOS thermal state serious or critical); battery at 10 % or less on battery power.
- Automatic resume only on a full wake (lid open, or lid closed with an external display), never during a
  maintenance wake.
- Pause when no temperature sensor is readable with the lid closed and no external display
  (`allowUnknownTemperatures` turns it off).
- `agentmode status --json`, a stable, versioned status for integrations.
- `agentmode --version` and `agentmode help`.
- `agentmode install` writes the path of the binary you ran into the LaunchAgent, so any install location
  works.
- Notifications in English, or in Spanish when Spanish is your first macOS language.
- `scripts/install.sh` (one-line install from a release) and `scripts/setup-privileges.sh` (the `sudoers` rule).
- A SwiftBar plugin in `extras/swiftbar`.

[Unreleased]: https://github.com/ULookLookMe/agent-mode/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ULookLookMe/agent-mode/releases/tag/v0.1.0
