# Verified facts

agentmode is built on facts measured before any code was written, on **one MacBook Pro (M5, macOS 27.2)** in
October 2026. Other Macs may differ; please report yours with the **Tested on my Mac** issue template.

| Fact | Evidence |
|---|---|
| `caffeinate -ids` does not prevent sleep when the lid closes on battery. | `pmset -g log`: 4 `Clamshell Sleep` events on 14–15 Oct with `caffeinate` running. |
| `sudo pmset -a disablesleep 1` does prevent it. | Lid closed for 74 s (15 Oct) and 4 min (16 Oct) with no sleep; 1 Hz sampling without gaps. |
| `SleepDisabled` is saved in the system power preferences, so it is expected to survive a restart. | `/Library/Preferences/com.apple.PowerManagement.plist`, `SystemPowerSettings` → `SleepDisabled = 1`. **A restart was not tested.** |
| With `disablesleep`, the keyboard backlight turns off within 1 s of closing the lid and comes back on opening. | CoreBrightness `isBacklightSuppressedOnKeyboard` = true; IOKit `kbd-backlight` `enabled = No`. |
| The internal display does **not** turn off when the lid closes: it stays on at normal brightness until the display sleep timer (2 min on battery, 10 min on the charger). This is why agentmode turns it off. | CoreGraphics `active=1`, `asleep=0` while closed; it turned off after 2 min 1 s. |
| "Display off" signature. | `CGDisplayIsAsleep` = 1, `CGDisplayIsActive` = 0, `IOMFBBrightnessLevel` of `disp0` = 0, and powerd logs `Display is turned off`. |
| With the lid closed and the Mac asleep, macOS wakes it briefly for maintenance (DarkWake) every 10–15 min, with network access. This is why a pause never resumes during a maintenance wake. | `pmset -g log`: 664 `DarkWake` events between 9 and 16 Oct. |
| Screen lock is immediate and does not stop processes. | `sysadminctl -screenLock status` = immediate; a user process kept running after the display turned off. |
| The macOS thermal signal does not react to sustained load. | 480 s with 10 threads at 100 %, lid open, on battery: `thermalState` = `nominal` and thermal pressure = 0 throughout. |
| Real temperatures can be read without root through the private `IOHIDEventSystemClient` API, and they follow the load. | 46 sensors: 24 chip `PMU tdie*`/`PMU2 tdie*`, 6 battery `gas gauge battery`, NAND and others. Under 180 s of load: chip max 38 → 90 °C, chip average 35 → 64 °C, battery 31.4 → 32.2 °C. Some readings are invalid (`PMU tdev1` = −9202 °C) and are discarded. |
| Clearing `disablesleep` with the lid closed does not put the Mac to sleep by itself. | Community report (Vorssaint Utils, PR #1741), confirmed live: agentmode runs `pmset sleepnow`, and the Mac slept 11 s after `agentmode off`. |

The sensor names (`tdie`, `battery`) were confirmed only on the M5. Other Apple silicon chips may name their
sensors differently, in which case `agentmode status` shows `Heat protection: limited` or `none`.
