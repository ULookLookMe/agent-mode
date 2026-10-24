## What and why

<!-- What this changes and the problem it solves. Link the issue: Closes #… -->

## How it was tested

<!-- Tests added, commands run, and any live check on a Mac (model and macOS version). -->

## Checklist

- [ ] A test in `Tests/AgentModeCoreTests` fails without this change and passes with it.
- [ ] `swift test`, `swift format lint --strict --recursive Sources scripts Package.swift` and
      `swift build -c release -Xswiftc -warnings-as-errors` pass.
- [ ] The safety invariants in `docs/architecture.md` still hold.
- [ ] `CHANGELOG.md` is updated under **Unreleased**.
