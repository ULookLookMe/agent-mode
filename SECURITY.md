# Security policy

agentmode changes how a MacBook sleeps, asks you to add a narrow `sudoers` rule, and reads temperature
sensors through a private macOS API. This page explains what that means and how to report a problem.

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x | Yes |
| < 0.1 | No |

Only the latest release gets fixes.

## Reporting a vulnerability

Please report privately through GitHub: open the repository's **Security** tab and choose **Report a
vulnerability**. Do not open a public issue for a security problem.

Include the agentmode version (`agentmode --version`), your Mac model and macOS version, and the steps to
reproduce. Expect a first answer within 7 days. This is a one-person project, so timelines are best effort.

## Threat model

**What runs with privileges.** Nothing in agentmode runs as root. The `sudoers` rule allows your user to
run exactly two commands without a password, with these exact arguments:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

`sudo` matches the arguments exactly, so the rule grants nothing else. `pmset sleepnow` and
`pmset displaysleepnow` need no root.

**What the rule is not tied to.** The rule is granted to your user, not to the agentmode binary. Any
process running as your user can run those two commands, so it can keep the Mac awake or let it sleep.
It cannot do anything else as root. Processes running as your user are out of scope: they can already read
and change everything in your account.

**Files.** State and logs live under your home folder (`~/Library/Application Support/agentmode`,
`~/Library/Logs/agentmode*`, `~/.config/agentmode`). They contain no secrets.

**Network.** The background process sends a `HEAD` request to `https://api.anthropic.com` and a `GET`
request to `https://captive.apple.com/hotspot-detect.html` every 60 seconds and whenever the network
changes, to detect a lost connection. The requests carry no data about you, use no cookies or cache, and
run whenever the background process runs, even with the mode off. You can change the hosts with
`probeURLs` in the configuration. agentmode has no telemetry or analytics.

**Private API.** Battery and chip temperatures are read with `IOHIDEventSystemClient`, a private macOS API.
It reads sensors only and needs no privileges. A macOS update can change or remove it. agentmode then
reports the temperatures as `unknown` and keeps working; see the safety notes below.

**Physical safety.** A MacBook that cannot sleep with the lid closed can heat up inside a bag. agentmode
pauses on heat, low battery and a lost connection, and with the lid closed it pauses when no temperature
sensor is readable. These protections were tested on one Mac. Read the **Safety** section of the README
before relying on them. If anything goes wrong, this restores normal sleep at once:

```sh
sudo pmset -a disablesleep 0
```

## Out of scope

- Processes running as your own user (see above).
- A Mac whose administrator account is already compromised.
- Damage from heat or a drained battery: the software is provided "as is", without warranty, as stated in
  the [LICENSE](LICENSE).
