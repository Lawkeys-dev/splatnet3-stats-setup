# splatnet3-stats-setup

Upload your Splatoon 3 battles to [stat.ink](https://stat.ink) automatically, without
handing your Nintendo `session_token` to anyone. Runs on **Linux** (systemd) and
**Windows** (Task Scheduler).

[s3s](https://github.com/frozenpandaman/s3s) does the uploading, and
[splatnet3-token-util](https://github.com/strohitv/splatnet3-token-util) (stu) gets the
SplatNet 3 tokens out of an Android emulator instead of a third-party f-generation API.
This repo is the glue: wrapper scripts, systemd user units or scheduled tasks, and a runner
that refreshes the tokens **only when they are actually dead** — and, most of the time,
without booting the emulator at all.

## The point: two-tier token refresh

s3s runs with `--norefresh 42`, so instead of refreshing tokens itself it exits with
rc 42 the moment SplatNet 3 rejects them. `bin/s3s-loop.py` catches that and refreshes
in two tiers, cheapest first:

| Tier | When | Cost |
|---|---|---|
| 1. new `bulletToken` from the stored `gtoken` | the `bulletToken` expired (~every 2 h) | one HTTPS POST to `splatnet3/api/bullet_tokens`, < 1 s |
| 2. full emulator extraction | the `gtoken` expired too (~every 6 h), or tier 1 failed | boots the AVD, ~40 s and a few GB of RAM |

A `gtoken` lives about 6 hours, a `bulletToken` about 2. stu's own `run_s3s.py` boots the
emulator for either, so it fires roughly every 2 hours; here two expiries out of three are
served by a single HTTPS call, and the emulator only wakes up when the `gtoken` is really
gone. Tier 1 needs nothing but the `gtoken` already in `config.txt` — no emulator, no
`session_token` leaving your machine, no f-gen API (`f_gen` stays `DUMMY_VALUE`).

Safety rails:

- the new `bulletToken` is validated with a `HomeQuery` before it is written to `config.txt`
- if s3s comes back asking for tokens less than 60 s after a tier-1 refresh, the next
  attempt skips straight to tier 2, so it cannot loop on a token it keeps rejecting
- automatic extractions run headless (`config-headless.json`); the windowed config is
  only used for interactive runs (`-im`)

## What's in here

| Path | OS | What |
|---|---|---|
| `bin/s3s-loop.py` | both | the runner: s3s + the two-tier refresh above (replaces stu's `run_s3s.py`) |
| `config/template.txt.example` | both | stu's token template |
| `install.sh` | Linux | clones the upstream projects, renders the configs, symlinks the wrappers, installs the units |
| `bin/stu*` (no extension) | Linux | wrappers that set `ANDROID_HOME`/`PATH` and the shared venv python |
| `systemd/` | Linux | user units: the s3s uploader service, plus an optional token-refresh timer |
| `config/linux/*.example` | Linux | the stu config files, with `__HOME__` / `__ROOT__` placeholders |
| `install.ps1` | Windows | clones the upstream projects, renders the configs, puts `bin\` on your PATH, registers the scheduled tasks |
| `bin/*.cmd` | Windows | wrappers that set `ANDROID_HOME`/`PATH` and run the shared venv python |
| `bin/supervise.pyw` | Windows | what the scheduled tasks start: no window, a log file, restart on exit, and the whole process tree (emulator included) dies with the task |
| `config/windows/*.example` | Windows | the stu config files, with `__ROOT__` / `__SDK__` / `__AVD_HOME__` placeholders |

Each [release](https://github.com/Lawkeys-dev/splatnet3-stats-setup/releases) has one
archive per OS that holds only that OS's files; a clone holds both. The two upstream
projects are cloned by the installers, not vendored.

## Requirements

On both:

- git and [uv](https://docs.astral.sh/uv/); uv fetches Python 3.12 by itself (3.13+ has no
  wheels for stu's pinned numpy/scipy)
- A Nintendo account that has played Splatoon 3 online, logged into the Nintendo Switch
  Online app inside the AVD below
- A stat.ink API token from <https://stat.ink/profile>

### Linux

- A systemd user session (developed on Arch/[Omarchy](https://omarchy.org))
- Android SDK: `cmdline-tools`, `platform-tools`, `emulator`, and an **API 30 Play Store**
  system image, with an AVD named `NSA` (cold boot, `swiftshader_indirect` GPU works well
  under Wayland). A JDK is needed for `sdkmanager`/`avdmanager` only.

### Windows

- Windows 10 or 11, **x64**, with hardware virtualization on: enable *Windows Hypervisor
  Platform* in "Turn Windows features on or off" (or install the *Android Emulator
  hypervisor driver* from the SDK Manager). Once installed, `stu-sdk emulator -accel-check`
  tells you whether acceleration works.
- [Git for Windows](https://git-scm.com/download/win), and uv with
  `winget install astral-sh.uv`
- [Android Studio](https://developer.android.com/studio) (it brings the SDK, the emulator
  and a JDK), with an AVD named **`NSA`**: hardware profile **Pixel 4** (not XL, not 4a),
  system image **API 30 "R", Google Play**, x86_64. Do not rename it afterwards.
  Command-line alternative, once `install.ps1` has put `bin\` on your PATH and the *SDK
  Command-line Tools* are installed:

  ```powershell
  stu-sdk sdkmanager "platform-tools" "emulator" "system-images;android-30;google_apis_playstore;x86_64"
  stu-sdk avdmanager create avd -n NSA -d pixel_4 -k "system-images;android-30;google_apis_playstore;x86_64"
  ```

## Install

Take the archive for your OS from the
[latest release](https://github.com/Lawkeys-dev/splatnet3-stats-setup/releases/latest), or
clone the repo. Either way you end up with a `splatnet3` folder.

### Linux

```bash
mkdir -p ~/Work
curl -fL https://github.com/Lawkeys-dev/splatnet3-stats-setup/releases/latest/download/splatnet3-stats-setup-linux.tar.gz | tar -xz -C ~/Work
#   or: git clone https://github.com/Lawkeys-dev/splatnet3-stats-setup.git ~/Work/splatnet3
cd ~/Work/splatnet3
./install.sh --venv          # clones s3s + stu, renders configs, symlinks bin/, installs units
```

`install.sh` never overwrites an existing config unless you pass `--force`, and it is safe
to re-run. It works from any directory, not just `~/Work/splatnet3` — the wrappers resolve
the checkout from their own location and the units are rewritten to match. If your SDK is
not in `~/Android/Sdk`, export `ANDROID_HOME` before running it: the configs and the units
then point at that SDK, and the units pass `ANDROID_HOME` on to the wrappers.

Then:

1. put your stat.ink token in `splatnet3-token-util/config/template.txt`
2. `stu --emu`, log into the Nintendo Switch Online app inside the emulator, open
   SplatNet 3 once, and update **Android System WebView** and **Chrome** from the Play
   Store (see the gotcha below)
3. `stu -im` — first extraction, press Enter once SplatNet 3 has loaded (the tokens are
   copied into `s3s` too)
4. `systemctl --user enable --now splatnet3-s3s.service`

### Windows

In PowerShell:

```powershell
Invoke-WebRequest https://github.com/Lawkeys-dev/splatnet3-stats-setup/releases/latest/download/splatnet3-stats-setup-windows.zip -OutFile $env:TEMP\splatnet3.zip -UseBasicParsing
Expand-Archive $env:TEMP\splatnet3.zip -DestinationPath $HOME
#   or: git clone https://github.com/Lawkeys-dev/splatnet3-stats-setup.git $HOME\splatnet3
cd $HOME\splatnet3
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Venv
```

`install.ps1` never overwrites an existing config unless you pass `-Force` (which rewrites
all four, `template.txt` and your stat.ink key included), and it is safe to re-run. It
works from any directory — the wrappers resolve the checkout from their own location and
the tasks point at wherever it lives. Keep it out of a OneDrive-synced folder: `config.txt`
holds live tokens. If your SDK is not in `%LOCALAPPDATA%\Android\Sdk`, set the user
environment variable `ANDROID_HOME` to it first (then open a new terminal), so both the
configs and the wrappers find it.

Then, **in a new terminal** (so `bin\` is on your PATH):

1. put your stat.ink token in `splatnet3-token-util\config\template.txt`
2. `stu --emu`, log into the Nintendo Switch Online app inside the emulator, open
   SplatNet 3 once, and update **Android System WebView** and **Chrome** from the Play
   Store (see the gotcha below)
3. `stu -im` — first extraction, press Enter once SplatNet 3 has loaded (the tokens are
   copied into `s3s` too)
4. `Enable-ScheduledTask splatnet3-s3s; Start-ScheduledTask splatnet3-s3s`

### Updating

Stop the uploader, extract the new release over the old folder (add `-Force` to
`Expand-Archive` on Windows) or `git pull` in a clone, re-run the installer without
`--force` / `-Force` but with `--venv` / `-Venv` (it adds new dependencies, and the `pip`
that stu's own update needs), and start the uploader again (see [Automation](#automation)).
Your configs, tokens, venv and the upstream clones are not in the archive, so they stay.

## Commands

The same on both OSes:

```bash
stu                      # extract tokens, emulator window visible
stu -im                  # interactive: press Enter when SplatNet 3 has loaded
stu --emu                # just boot the emulator (manual setup / re-login)
stu --adb="devices"      # run an adb command against the emulator
stu-headless             # one-shot extraction, no emulator window, no s3s
stu-s3s --getseed        # s3s: export gear file for Lean's Gear Seed Checker
stu-s3s -r               # s3s: upload recent battles to stat.ink
stu-s3s -r -M            # s3s: upload + monitoring mode (what the service / task runs)
stu-s3s-upstream -r -M   # same, but with stu's own loop (emulator on every expiry)
stu-sdk sdkmanager --list        # SDK manager with a JDK in JAVA_HOME
stu-sdk avdmanager list avd
```

## Automation

The uploader is a long-running s3s in monitoring mode that uploads battles as you play.
It runs `stu-s3s -r -M`:

- `-r` on start: upload anything stat.ink is missing (up to 250 battles + 50 jobs)
- `-M` then: poll SplatNet 3 every 300 s and upload each new battle/job as it finishes
- on rc 42, `s3s-loop.py` refreshes per the table above and restarts s3s — token refresh
  is **on demand**, never on a clock

### Linux: the systemd service

`splatnet3-s3s.service` runs it:

```bash
systemctl --user status splatnet3-s3s.service      # is it running
journalctl --user -u splatnet3-s3s.service -f      # watch uploads live
systemctl --user restart splatnet3-s3s.service     # after config changes
systemctl --user disable --now splatnet3-s3s.service   # stop uploading
```

### Windows: the scheduled task

The `splatnet3-s3s` task runs it, starting a minute after you log on:

```powershell
Get-ScheduledTask splatnet3-s3s | Get-ScheduledTaskInfo                # last run, last result
Get-Content $HOME\splatnet3\logs\s3s.log -Wait -Tail 50                # watch uploads live
Stop-ScheduledTask splatnet3-s3s; Start-ScheduledTask splatnet3-s3s    # after config changes
Stop-ScheduledTask splatnet3-s3s; Disable-ScheduledTask splatnet3-s3s  # stop uploading
```

The task runs as you, only while you are logged on (no stored password, no elevation),
keeps running on battery, and has no time limit.

Task Scheduler cannot do much of what the Linux units rely on, so the tasks do not run
the `.cmd` wrapper directly: they start `pythonw.exe bin\supervise.pyw`, which runs it and
fills the gaps.

| systemd, on Linux | Windows |
|---|---|
| runs in the background | `pythonw.exe` has no console, and the wrapper gets a hidden one (`CREATE_NO_WINDOW`): no window, ever |
| the journal | `logs\s3s.log` / `logs\tokens.log`, one timestamped line per line, rotated to `.1` at 5 MB. s3s's once-a-second countdown is collapsed to what a terminal would show |
| `Restart=always`, `RestartSec=60s`, `StartLimitBurst=5` in 600 s | the same numbers, in `supervise.pyw --restart` |
| `StandardInput=null` | stdin is closed (see below) |
| `ExecStopPost=… adb emu kill` | the wrapper's whole process tree sits in a kill-on-close job object: stopping the task, or logging off, kills the emulator too |
| `Conflicts=` | not available; `stu-headless` refuses to boot a second emulator while one is running |

### The hourly token refresh is deliberately off

`splatnet3-tokens.timer` on Linux and the `splatnet3-tokens` task on Windows are installed
but **not enabled**. They boot their own emulator, and stu cannot cope with two emulators
at once, so they would collide with the on-demand refresh. On Linux the units carry
`Conflicts=` so systemd will not run both. Only turn it on if you turn the uploader off and
just want a fresh `config.txt` on a schedule:

```bash
systemctl --user disable --now splatnet3-s3s.service
systemctl --user enable --now splatnet3-tokens.timer
```

```powershell
Stop-ScheduledTask splatnet3-s3s; Disable-ScheduledTask splatnet3-s3s
Enable-ScheduledTask splatnet3-tokens
```

### Two details worth knowing

- **No stdin** (`StandardInput=null` in the unit, closed by `supervise.pyw` on Windows):
  s3s calls `input()` at startup whenever a newer version exists upstream and `.git` is
  present. In the background that would hang forever. With no stdin it raises `EOFError`
  instead, the service or `supervise.pyw` restarts it, and `s3s_update` git-pulls it
  current — self-healing rather than silently stuck.
- **`s3s_update: true`** in `config_run_s3s.json` makes `s3s-loop.py` run `git pull` in the
  s3s directory on each start, then refresh its dependencies (with `uv pip` when the venv
  has no `pip`; a failure there is logged and does not stop the loop). That means it
  auto-runs new upstream code without review — it is the s3s project's own update path
  and is what keeps the prompt above from firing. Set it to `false` to update by hand.

## Config files

Relative to the `splatnet3` folder (with `\` on Windows):

- `splatnet3-token-util/config/config.json` — windowed run (interactive/debug)
- `splatnet3-token-util/config/config-headless.json` — same plus `-no-window -no-audio`;
  used by `stu-headless`, the hourly timer / task, and every automatic extraction
- `splatnet3-token-util/config/template.txt` — token template; **put your stat.ink token in
  `api_key`**. `session_token` stays `skip`: it is never extracted or stored.
- `splatnet3-token-util/config_run_s3s.json` — s3s directory, venv python, refresh rc.
  Shared with `run_s3s.py`, so `stu-s3s-upstream` keeps working.

`config.txt` (both copies) holds live tokens and your stat.ink key — it is gitignored, keep
it that way.

Note: stu rewrites its `config.json` on every run, so hand edits to fields it does not know
about are dropped.

On Windows:

- When editing paths in these JSON files, double every backslash:
  `C:\\Users\\you\\...`, not `C:\Users\you\...`.
- stu turns every space in `adb_path` into an underscore, so an SDK under a profile such as
  `C:\Users\Jean Dupont` would not be found. `install.ps1` writes the SDK's 8.3 short path
  (`C:\Users\JEANDU~1\...`) in that case; if the volume has no short names, it warns and
  you need an SDK path without spaces, such as `C:\Android\Sdk`.

## Known gotcha: the emulator's WebView

The API 30 system image ships **Chrome and Android System WebView 83 (mid-2020)**. SplatNet 3
refuses to render on it and shows *"SplatNet 3 cannot be displayed"*, which makes stu's
`open_splatnet3` step fail all 3 attempts with no useful error.

Fix it by updating both through the Play Store inside the emulator (83 → current). **If
extraction starts failing months later, check this first** — the emulator does not update
them reliably:

```bash
stu --emu    # boot, then update "Android System WebView" and "Chrome" in the Play Store
# check versions without the UI:
adb shell "dumpsys package com.google.android.webview | grep -m1 versionName"
adb shell "dumpsys package com.android.chrome | grep -m1 versionName"
```

stu's detection step looks for the SplatNet 3 background colour `#292E35` filling 30–70 % of
the box x=0..1000, y=1000..1500. The error page fills ~97 % of that box, so it reads as a
failure; a correctly loaded main menu measures ~46 %.

## Troubleshooting

- Automatic extraction fails → `stu -im`, press Enter once SplatNet 3 is on screen.
- Emulator won't start → `stu --adb="emu kill"`, then `stu --emu`. Still nothing on
  Windows: `stu-sdk emulator -accel-check`, and check that virtualization is on (see
  Requirements).
- Rendering issues → `hw.gpu.mode` in the AVD's `config.ini` (`~/.android/avd/NSA.avd/` on
  Linux, `%USERPROFILE%\.android\avd\NSA.avd\` on Windows). On Linux,
  `swiftshader_indirect` is reliable and `host` faster but flakier under Wayland; on
  Windows, `host` is fastest and `swiftshader_indirect` is the fallback when the GPU driver
  misbehaves.
- Tokens refresh in a loop → the log tells you which tier ran; a tier-2 run that ends in
  `ERROR DURING TOKEN EXTRACTION` is usually the WebView gotcha above.
- Windows, the task does not seem to run → `Get-ScheduledTaskInfo splatnet3-s3s`
  (`LastTaskResult`), then `logs\s3s.log`. The last line says why it stopped: a crash,
  `ERROR DURING s3s`, or five restarts in ten minutes (then
  `Start-ScheduledTask splatnet3-s3s` once fixed).
- Windows, `adb_path in config does not exist` → the SDK path has a space, see Config files.

## Releases

Pushing a `v*` tag builds both archives and publishes the release
(`.github/workflows/release.yml`):

```bash
git tag v1.1.0 && git push origin v1.1.0
```

## Credits

- [s3s](https://github.com/frozenpandaman/s3s) by frozenpandaman — the uploader
- [splatnet3-token-util](https://github.com/strohitv/splatnet3-token-util) by strohitv — the
  emulator-based token extraction
- [stat.ink](https://stat.ink) by fetus-hina

This repo only contains the glue around them.

## License

[MIT](LICENSE). s3s and splatnet3-token-util, which the installers clone, keep their own
licenses.
