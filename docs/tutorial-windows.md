# Step-by-step setup on Windows

This guide takes you from nothing to "my Splatoon 3 battles show up on stat.ink by
themselves". No technical background needed: copy each command into PowerShell, one
block at a time, and check that you get what the guide says before moving on.

It takes about **45 minutes**, most of it waiting for downloads.

> Just want the reference? Everything here is also in the [README](../README.md), in a
> shorter form.

## What you will end up with

- a small background task that watches SplatNet 3 and sends every new battle and Salmon
  Run job to stat.ink a few minutes after it ends. It has no window and starts by itself
  when you log in
- a hidden Android phone (an emulator) on your PC, used only when Nintendo's login tokens
  need renewing. It starts and stops by itself; you never have to touch it again after setup
- your Nintendo `session_token` never leaves your PC

## Before you start

You need:

| | |
|---|---|
| A **Nintendo account** | that has played Splatoon 3 online at least once |
| A **Google account** | to use the Play Store inside the emulator (a spare one is fine) |
| A **stat.ink account** | free, at <https://stat.ink> |
| **Windows 10 or 11**, 64-bit | on an Intel or AMD processor (not ARM) |
| **~15 GB** of free disk and **4 GB** of free RAM | the emulator needs them while it runs |

## How to open PowerShell

Press the **Windows key**, type `powershell`, and click **Windows PowerShell**. Don't pick
"Run as administrator" unless this guide says so.

Several steps say **"open a new PowerShell window"**: close the current one and open
another, so it sees what was just installed.

## Step 1: turn on virtualization

The emulator needs Windows' virtualization support.

1. Press the **Windows key**, type `Turn Windows features on or off`, and open it.
2. Tick **Windows Hypervisor Platform**, click **OK**, and restart the PC when asked.

(If it was already ticked, nothing to do.)

## Step 2: install the tools

In PowerShell:

```powershell
winget install Git.Git
winget install astral-sh.uv
winget install Google.AndroidStudio
```

Accept the prompts. Git is a download tool, uv installs Python, and Android Studio brings
the Android emulator. **Open a new PowerShell window** afterwards.

## Step 3: create the Android phone

1. Open **Android Studio** from the Start menu. On first launch, accept the defaults
   (*Standard* setup) and let it download what it needs. This takes a while.
2. On the welcome screen, click **More Actions → Virtual Device Manager**. If a phone is
   already listed there, delete it (**⋮ → Delete**).
3. Click **+** (*Create Virtual Device*) and set:
   - device: **Pixel 4**. Not "Pixel 4 XL", not "Pixel 4a".
   - system image: **API 30 "R"** with **Google Play**, x86_64. Click the download icon
     next to it if needed.
   - name: **`NSA`**, exactly like that. Never rename it later.
   - in the additional settings: boot method **Cold Boot**.
4. Click **Finish**, then **close Android Studio**. From now on, never start the phone from
   Android Studio: this setup does it for you.

The illustrated version of this step, with screenshots, is in
[splatnet3-token-util's guide](https://github.com/strohitv/splatnet3-token-util/blob/main/quickstart_s3s_guide.md#create-an-android-emulator--android-virtual-device-avd).

## Step 4: download and install this setup

In PowerShell:

```powershell
Invoke-WebRequest https://github.com/Lawkeys-dev/splatnet3-stats-setup/releases/latest/download/splatnet3-stats-setup-windows.zip -OutFile $env:TEMP\splatnet3.zip -UseBasicParsing
Expand-Archive $env:TEMP\splatnet3.zip -DestinationPath $HOME
cd $HOME\splatnet3
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Venv
```

It downloads the two projects doing the real work (s3s and splatnet3-token-util) and a
private copy of Python, and adds a few commands (`stu`, `stu-s3s`, `stu-sdk`...). It ends
with `== done. remaining manual steps:`. You can ignore that list: this guide covers it.

- A warning about the scheduled tasks and **"Access is denied"**: run the last line again
  in a PowerShell opened with *Run as administrator*. The tasks still run as you, not as
  administrator.
- A warning **"no Android SDK"**: Android Studio did not finish its first launch. Open it
  once more, let it finish, then run the last line again.

**Open a new PowerShell window**, then check that the emulator can run at full speed:

```powershell
stu-sdk emulator -accel-check
```

It should say that WHPX (or AEHD) is installed and usable. If not, go back to step 1.

## Step 5: add your stat.ink key

1. Go to <https://stat.ink/profile> and copy the **API Token**.
2. Open the settings file in Notepad:

   ```powershell
   notepad $HOME\splatnet3\splatnet3-token-util\config\template.txt
   ```

3. Replace `PUT_YOUR_STATINK_API_TOKEN_HERE` with your token, keeping the quotes:

   ```json
   "api_key": "aBcD1234...",
   ```

4. Save (**Ctrl+S**) and close Notepad.

Don't change anything else in that file.

## Step 6: set up the phone

Start the phone:

```powershell
stu --emu
```

A phone window opens. The first start takes a minute or two. You can type with your PC's
keyboard. Then, inside the phone:

1. **Turn on Do Not Disturb**: swipe down from the top of the screen and tap *Do Not
   Disturb*. Notifications would get in the way of the automation.
2. **Sign in to Google**: open the *Play Store* app and sign in with your Google account.
   Decline the backup option.
3. **Update the web browser parts.** This matters: the phone ships with a 2020 web
   engine that SplatNet 3 refuses to run on. In the Play Store, tap your profile picture
   (top right) → *Manage apps & device* → *Update all*. Make sure **Android System
   WebView** and **Chrome** are in the list; if not, search for each of them and tap
   *Update*.
4. **Install the Nintendo Switch app**: search for *Nintendo Switch App* in the Play Store
   and install it.
5. **Sign in to Nintendo**: open the Nintendo Switch app, tap *Sign in*, and log in with
   your Nintendo account. Pick your user, tap through the introduction screens, and refuse
   the notifications.
6. **Open SplatNet 3 once**: in the app, tap the Splatoon 3 banner. SplatNet 3 should
   load and show your stats. If it says *"SplatNet 3 cannot be displayed"*, go back to
   point 3.

When SplatNet 3 has loaded, turn the phone off from PowerShell:

```powershell
stu --adb="emu kill"
```

## Step 7: first token extraction

```powershell
stu -im
```

The phone starts again and opens SplatNet 3 by itself. **Wait until SplatNet 3's main
menu is on screen, then press Enter in PowerShell.** The phone closes, and the tokens are
read and saved.

If it ends with an error, run it again: the first run is sometimes slow.

## Step 8: start uploading

```powershell
Enable-ScheduledTask splatnet3-s3s; Start-ScheduledTask splatnet3-s3s
```

Watch it work:

```powershell
Get-Content $HOME\splatnet3\logs\s3s.log -Wait -Tail 50
```

After a minute or so you should see `Validating your tokens... done.`, then, if stat.ink
is missing some of your recent battles, lines like:

```text
Battle uploaded to https://stat.ink/@you/spl3/...
```

Press **Ctrl+C** to stop watching (the task keeps running). Your battles are now on your
stat.ink profile, and new ones get there about 5 minutes after each match.

**You're done.** The task starts by itself a minute after you log in to Windows.

## Everyday use

There is nothing to do. When the tokens expire, the task renews them on its own: usually
with a single request to Nintendo, and every few hours by quietly starting the hidden
phone for about a minute.

The task only runs while you are logged in and the PC is awake. Battles played while the
PC was off are not lost: they are sent the next time it runs (SplatNet 3 keeps your last
50 battles of each type).

Useful commands:

```powershell
Get-ScheduledTask splatnet3-s3s | Get-ScheduledTaskInfo                # when did it last run?
Get-Content $HOME\splatnet3\logs\s3s.log -Wait -Tail 50                # watch the uploads live
Stop-ScheduledTask splatnet3-s3s; Start-ScheduledTask splatnet3-s3s    # restart it
Stop-ScheduledTask splatnet3-s3s; Disable-ScheduledTask splatnet3-s3s  # stop uploading for good
```

## Updating

```powershell
Stop-ScheduledTask splatnet3-s3s
Invoke-WebRequest https://github.com/Lawkeys-dev/splatnet3-stats-setup/releases/latest/download/splatnet3-stats-setup-windows.zip -OutFile $env:TEMP\splatnet3.zip -UseBasicParsing
Expand-Archive $env:TEMP\splatnet3.zip -DestinationPath $HOME -Force
cd $HOME\splatnet3
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Venv
Start-ScheduledTask splatnet3-s3s
```

Your settings, tokens and stat.ink key are kept.

## Something went wrong?

| Symptom | Fix |
|---|---|
| `stu` is not recognized | open a new PowerShell window. Still not found: run `install.ps1` again (step 4) |
| the phone window never appears | `stu --adb="emu kill"`, then `stu --emu` again. Still nothing: `stu-sdk emulator -accel-check`, and check step 1 |
| `adb_path in config does not exist` | your Windows user name has a space and the installer could not work around it: see *Config files* in the [README](../README.md#config-files) |
| *"SplatNet 3 cannot be displayed"* | update **Android System WebView** and **Chrome** in the Play Store (step 6, point 3) |
| the extraction fails 3 times | `stu -im`, and press Enter only once SplatNet 3 is fully on screen |
| no `Battle uploaded` line | check that your stat.ink key is in `template.txt` (step 5), then run `stu -im` again so it is copied over |
| it worked for months, then stopped | the phone's WebView is probably out of date again: `stu --emu`, update it, `stu --adb="emu kill"` |

Still stuck? The last lines of `$HOME\splatnet3\logs\s3s.log` usually say what is wrong.
The [README](../README.md#troubleshooting) has more details.
