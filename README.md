# Insomnia

Keep a MacBook running with the lid closed, so background work survives: **VS Code, Remote-SSH sessions, long builds, downloads, servers.**

Close the lid, walk away, and come back to an SSH session that never dropped.

---

## Why this needs an app at all

macOS treats closing the lid as *mandatory* sleep. The usual tools do not help:

| Approach | Survives lid close? |
|---|---|
| `caffeinate` / `caffeinate -i` | **No** — idle-sleep assertions are bypassed by clamshell sleep |
| IOKit wake assertions (most "keep awake" apps) | **No** — same reason |
| External display + charger ("clamshell mode") | Yes, but requires a monitor |
| **`pmset -a disablesleep 1`** | **Yes** — the only supported switch |

`disablesleep` is a system-wide, root-only setting. Insomnia drives it, verifies the result, and puts it back when you are done.

---

## What it does

**With the mode ON**

- **Lid closed** → the screen goes off, the system stays awake, VS Code and SSH keep running. The app reads the hardware lid sensor and the real display power state, and forces the panel off if anything leaves it lit.
- **Lid open** → nothing is forced. The screen comes back on like a normal Mac and display sleep follows your normal timer.

**Timer** — a second page with presets (15 min … 8 h) or a custom duration. The countdown is enforced by a small root-side job, so sleep is restored *automatically* when it expires — no password prompt, and it still works if the app is closed.

**SSH keepalive** — keeping the Mac awake does not stop a NAT router or firewall from reaping an idle connection. One button appends `ServerAliveInterval` settings to `~/.ssh/config` (your config is backed up first, and it never touches one that already sets them).

**Safety**

- Warns when you enable it on battery, and can auto-revert if you unplug mid-session
- Everything is logged to `/tmp/lidkeepawake.log` so you can verify what happened

**What it does not do** — no kernel extension, no network access, no telemetry, no auto-updater. The only privileged piece is an optional 90-line root-owned shell script (see below), which you can remove at any time.

---

## Requirements

- **macOS 13 (Ventura) or later.** Built and tested on macOS 15.6 (Sequoia).
- A Mac with a **lid** (any MacBook) for the lid features. On a desktop Mac it still works as a plain sleep-blocker.
- **Xcode Command Line Tools** — the Swift toolchain. Full Xcode is *not* required:

  ```sh
  xcode-select --install
  swift --version        # expect "Apple Swift version 5.9+" / 6.x
  ```

  Already have Xcode? You're set.
- No Apple Developer account, no notarization, no dependencies to install.

---

## Compile and run on a new system

**1. Get the source**

```sh
# via git
git clone <your-repo-url> Insomnia && cd Insomnia

# or just copy the folder over (AirDrop, scp, USB) and cd into it
```

**2. Build, package and sign the app** (one command):

```sh
./build_app.sh
```

This runs `swift build -c release`, assembles `build/Insomnia.app` with its `Info.plist` (`LSUIElement=true`, so it lives in the menu bar with no Dock icon), ad-hoc code-signs it, and clears any quarantine flag.

**3. Run it**

```sh
open build/Insomnia.app
```

The app has **no Dock icon and no window** — look for the **moon icon (`🌙 zzz`) in the menu bar**, left of the clock.

**4. Install it permanently** (optional, and this is what removes the password prompts):

```sh
./build_app.sh --install
```

This copies the app to `/Applications` **and** sets up the privileged helper, asking for your admin password **exactly once**. Launch it from Spotlight afterwards.

**Prefer to run without a bundle?** `swift run -c release` also works, but without the `.app` bundle it cannot report its name and menu-bar behavior is less reliable — use the script.

### Packaging and releasing (`.dmg`)

```sh
./build_app.sh --dmg                 # → build/Insomnia-1.0.dmg
gh release create v1.0 build/Insomnia-1.0.dmg --title "Insomnia v1.0" --notes "..."
```

The flag stages the app next to an `/Applications` symlink (the usual drag-to-install layout), compresses it, then mounts the image to confirm the app and symlink are really inside before finishing. Flags combine, so `./build_app.sh --dmg --install` packages and installs in one go.

**A caveat for releases:** the app is ad-hoc signed (no Developer ID, no notarization). Downloaders will see Gatekeeper warn, so your release notes should say *right-click the app → Open* the first time, or `xattr -dr com.apple.quarantine /Applications/Insomnia.app`. Notarization requires a paid Apple Developer account.

### Passwords: asked once, not every time

Changing the system sleep setting means running `pmset` as root, so out of the box every toggle would prompt. `./build_app.sh --install` (or the app's **"Set up once — no more passwords"** button) fixes that permanently by installing two files:

- `/usr/local/libexec/insomnia-helper` — a small root-owned shell script that does the sleep work
- `/etc/sudoers.d/insomnia` — a rule letting *your* account run only that script without a password

After that, toggling is instant and silent. The script accepts only five fixed subcommands (`ping`, `enable`, `enable-timer <seconds>`, `disable`, `cancel-timer`, plus an internal revert step) and validates every argument, so the rule cannot be used to run arbitrary commands as root — the worst it grants is keeping this Mac awake. Both files are root-owned and not writable by your user account.

To go back to password-on-every-toggle: `./helper/uninstall_helper.sh` (or the app's **"Remove password-free helper"** button).

### First launch

With the helper set up, nothing prompts you. Without it, the first time you flip **"Keep running when lid is closed"** macOS asks for your **admin password** (that prompt may appear behind other windows — look for a hidden `osascript wants to make changes` dialog), and it asks again on every later toggle.

If Gatekeeper complains (only likely when the folder arrived as a download), either right-click the app → **Open** → **Open**, or run:

```sh
xattr -dr com.apple.quarantine build/Insomnia.app
```

---

## Using it

1. Plug in the charger (recommended — a fanless MacBook Air gets warm with the lid shut on battery).
2. Click the menu bar icon → toggle **Keep running when lid is closed**. If you have not set up the helper yet, do that first (button in the same popover, one password prompt ever).
3. Close the lid. The screen goes off; VS Code, SSH connections and anything else keep running.
4. Open the lid → the screen comes back and everything behaves normally.
5. Turn the toggle off when you're finished (or set a **Timer** instead and let it revert itself).

**Verify it worked**, after a close/open cycle:

```sh
cat /tmp/lidkeepawake.log        # lid events, forced screen-off, timer expiry
pmset -g | grep -i sleepdisabled # 1 = awake mode on
pgrep -x Code                    # VS Code still alive
pmset -g log | grep -i "sleep" | tail -5
```

---

## Caveats worth knowing

- **`disablesleep` is system-wide and persistent.** It does not reset when the app quits or the Mac reboots — turn the mode off (or use the Timer) so you don't drain the battery. `pmset -a disablesleep 0` restores normal sleep from any terminal.
- **While the mode is armed, idle sleep is blocked even with the lid open.** This is unavoidable: the flag must already be set when the lid closes, otherwise macOS evaluates clamshell sleep first and the Mac sleeps. In practice it costs nothing — VS Code itself already holds a no-idle-sleep assertion while running.
- **Never leave it in a bag while awake on battery.** Heat has nowhere to go with the lid shut.
- **Wake-on-lid-open only works when the screen was physically off**, which is the normal case.
- **Any external input wakes the screen.** A Bluetooth or USB mouse, keyboard, gamepad or presenter keeps working with the lid shut, and its very first event lights the display. The app re-blanks within a second and logs it, but for a screen that stays truly dark, switch the device off.
- The project directory, Swift target and log path still use the internal name `LidKeepAwake`; only the user-visible app name is **Insomnia**. The `~/.ssh/config` marker block also keeps its original `LidKeepAwake` label so existing installs are detected.

---

## Project layout

```
Insomnia/
├── Package.swift          # SwiftPM manifest (executable target)
├── build_app.sh           # build → Insomnia.app → ad-hoc sign (--install: + helper)
├── Info.plist             # reference copy of the bundle plist
├── README.md
├── helper/
│   ├── insomnia-helper    # the root-owned privileged script
│   ├── install_helper.sh  # installs it + /etc/sudoers.d/insomnia (one prompt)
│   └── uninstall_helper.sh
├── Sources/
│   └── LidKeepAwake/
│       └── main.swift     # the entire app (~650 lines)
└── build/
    └── Insomnia.app       # build output
```

Everything lives in `main.swift`: power/`pmset` control, the root-side timer job, lid + display state, SSH keepalive, and the two-page SwiftUI menu bar UI. The three scripts under `helper/` are bundled into the app so the one-time setup button works on any machine.

---

## Troubleshooting

**No icon in the menu bar.** The menu bar may be full — macOS hides overflow items, so close a few apps' menus or remove other icons. Also check the app is actually running: `pgrep -fl LidKeepAwake`. On Macs with a notch, items hide left of the notch first.

**Toggle won't turn on.** You are on battery and the safety warning applies, or the password dialog was cancelled. The reason is printed right in the popover; `pmset -g | grep -i sleepdisabled` shows the authoritative state.

**Screen stays lit with the lid shut.** Look at `/tmp/lidkeepawake.log`. One `forcing display sleep` line per lid-close is normal — it means the panel was still lit at the instant the lid shut, and the app blanked it. (`asleep now:` is *not* printed any more: `pmset` returns before the panel finishes powering down, so an immediate re-read used to report the wrong state.) If you instead see lines like `panel woken again while lid closed`, an **external input device is doing it**: any Bluetooth or USB mouse, keyboard, gamepad or presenter wakes the display on any event, and those keep working with the lid shut. Turn the device off (or disconnect it) for a guaranteed dark screen. To rule out a display assertion from a running app as well: `pmset -g assertions | grep -i display`.

**SSH still drops.** Confirm the keepalive landed (`grep ServerAlive ~/.ssh/config`), then check the idle timeout on the *remote* side and any VPN/firewall in between. For long sessions, run your work inside `tmux` or `screen` on the remote host so the process outlives the connection.

**It still asks for my password on every toggle.** The helper isn't installed (or its rule was removed). Run `./build_app.sh --install`, or click **"Set up once — no more passwords"** in the popover; the **Password** row should then read *"Never asked — helper installed"*. Verify from a terminal with `sudo -n /usr/local/libexec/insomnia-helper ping` — it prints `ok` with no prompt.

**The Mac slept anyway.** The mode was not armed when the lid closed (the timer expired, or auto-revert fired). The log shows exactly which.

---

## Uninstall

```sh
# 1. Restore normal sleep
sudo pmset -a disablesleep 0

# 2. Remove the privileged helper and its passwordless rule, if you installed them
sudo ./helper/uninstall_helper.sh

# 3. Quit and remove the app
pkill -f Insomnia.app
rm -rf /Applications/Insomnia.app build/Insomnia.app

# 4. Clean up runtime state
sudo rm -rf /var/tmp/lidkeepawake
rm -f /tmp/lidkeepawake.log

# 5. Optional: remove the SSH keepalive block from ~/.ssh/config
#    (delete the lines between "# >>> LidKeepAwake keepalive >>>" and
#     "# <<< LidKeepAwake keepalive <<<"); a backup is at
#     ~/.ssh/config.lidkeepawake.bak
```
