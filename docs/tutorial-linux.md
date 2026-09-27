# Step-by-step setup on Linux

This guide takes you from nothing to "my Splatoon 3 battles show up on stat.ink by
themselves". No Linux expertise needed: copy each command into a terminal, one block at a
time, and check that you get what the guide says before moving on.

It takes about **45 minutes**, most of it waiting for downloads.

> Just want the reference? Everything here is also in the [README](../README.md), in a
> shorter form.

## What you will end up with

- a small background service that watches SplatNet 3 and sends every new battle and Salmon
  Run job to stat.ink a few minutes after it ends
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
| A PC with **virtualization** | Intel VT-x or AMD-V turned on in the BIOS (it usually is) |
| **~15 GB** of free disk and **4 GB** of free RAM | the emulator needs them while it runs |
| A **systemd** Linux distribution | Arch, Ubuntu, Debian, Fedora... almost all of them |

## Step 1: install the tools

Open a terminal and install git, uv (a Python installer), a Java runtime (only used to
download the Android tools) and unzip. Pick the line for your distribution:

```bash
# Arch / Manjaro / Omarchy
sudo pacman -S --needed git uv jdk21-openjdk unzip

# Ubuntu / Debian / Mint
sudo apt install git openjdk-21-jdk-headless unzip curl
curl -LsSf https://astral.sh/uv/install.sh | sh

# Fedora
sudo dnf install git uv java-21-openjdk-devel unzip
```

If you installed uv with the `curl` line, **close the terminal and open a new one** so it
is found.

Check that your PC can run the emulator at full speed:

```bash
ls -l /dev/kvm
```

- You see a line starting with `crw-rw-rw-`: all good.
- You see `crw-rw----` with `kvm`: add yourself to the `kvm` group, then **log out and back
  in**:

  ```bash
  sudo usermod -aG kvm "$USER"
  ```

- `No such file or directory`: virtualization is off. Turn on *Intel VT-x* / *SVM (AMD-V)*
  in your BIOS/UEFI settings and try again.

## Step 2: download and install this setup

```bash
mkdir -p ~/Work
curl -fL https://github.com/Lawkeys-dev/splatnet3-stats-setup/releases/latest/download/splatnet3-stats-setup-linux.tar.gz | tar -xz -C ~/Work
cd ~/Work/splatnet3
./install.sh --venv
```

It downloads the two projects doing the real work (s3s and splatnet3-token-util) and a
private copy of Python. It ends with `== done. remaining manual steps:`. You can ignore
that list: this guide covers it.

It also adds a few commands (`stu`, `stu-s3s`, `stu-sdk`...) to `~/.local/bin`. If `stu`
is "command not found" in a new terminal, add that folder to your PATH:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

## Step 3: install the Android emulator

Pick **one** of these two ways.

### Option A: command line (lighter, recommended)

1. Download the Android command-line tools:

   ```bash
   cd /tmp
   url=$(curl -s https://developer.android.com/studio | grep -oE 'https://dl.google.com/android/repository/commandlinetools-linux-[0-9]+_latest.zip' | head -1)
   curl -fLo cmdline-tools.zip "$url"
   mkdir -p ~/Android/Sdk/cmdline-tools
   unzip -q cmdline-tools.zip && mv cmdline-tools ~/Android/Sdk/cmdline-tools/latest
   ```

   If `curl` complains about an empty URL, download *Command line tools only* for Linux by
   hand from <https://developer.android.com/studio> (bottom of the page) and unzip it so
   that `~/Android/Sdk/cmdline-tools/latest/bin/sdkmanager` exists.

2. Download the emulator and an Android 11 phone image (about 2 GB), then create the
   phone, called `NSA`:

   ```bash
   yes | stu-sdk sdkmanager --licenses >/dev/null
   stu-sdk sdkmanager "platform-tools" "emulator" "system-images;android-30;google_apis_playstore;x86_64"
   echo no | stu-sdk avdmanager create avd -n NSA -d pixel_4 -k "system-images;android-30;google_apis_playstore;x86_64"
   ```

   A `Could not load devices from ... devices.xml` message here is harmless.

3. Adjust the phone's settings (the command-line tool leaves the Play Store and your
   keyboard off):

   ```bash
   sed -i -e 's/^PlayStore.enabled=.*/PlayStore.enabled=yes/' -e 's/^hw.keyboard=.*/hw.keyboard=yes/' \
          -e 's/^hw.gpu.enabled=.*/hw.gpu.enabled=yes/' -e 's/^hw.gpu.mode=.*/hw.gpu.mode=swiftshader_indirect/' \
          -e 's/^fastboot.forceColdBoot=.*/fastboot.forceColdBoot=yes/' -e 's/^fastboot.forceFastBoot=.*/fastboot.forceFastBoot=no/' \
          ~/.android/avd/NSA.avd/config.ini
   ```

### Option B: Android Studio

Install [Android Studio](https://developer.android.com/studio) (on Arch: `android-studio`
from the AUR), open it once, and let it install the SDK in `~/Android/Sdk`. Then create
the phone in *More Actions → Virtual Device Manager → +*:

- device **Pixel 4** (not XL, not 4a)
- system image **API 30 "R"**, **Google Play**, x86_64 (download it if asked)
- name **`NSA`**, exactly, and never rename it
- in the additional settings, boot method **Cold Boot**

Close Android Studio afterwards, and never start the phone from it: always use `stu`.

The illustrated version of these steps, with screenshots, is in
[splatnet3-token-util's guide](https://github.com/strohitv/splatnet3-token-util/blob/main/quickstart_s3s_guide.md#create-an-android-emulator--android-virtual-device-avd).

### Check

```bash
stu-sdk emulator -accel-check
```

should end with `KVM ... is installed and usable`.

## Step 4: add your stat.ink key

1. Go to <https://stat.ink/profile> and copy the **API Token**.
2. Open the settings file:

   ```bash
   nano ~/Work/splatnet3/splatnet3-token-util/config/template.txt
   ```

3. Replace `PUT_YOUR_STATINK_API_TOKEN_HERE` with your token, keeping the quotes:

   ```json
   "api_key": "aBcD1234...",
   ```

4. Save with **Ctrl+O**, **Enter**, then quit with **Ctrl+X**.

Don't change anything else in that file.

## Step 5: set up the phone

Start the phone:

```bash
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

When SplatNet 3 has loaded, turn the phone off from the terminal:

```bash
stu --adb="emu kill"
```

## Step 6: first token extraction

```bash
stu -im
```

The phone starts again and opens SplatNet 3 by itself. **Wait until SplatNet 3's main
menu is on screen, then press Enter in the terminal.** The phone closes, and the tokens
are read and saved (in `splatnet3-token-util/config.txt`, copied to `s3s/` too).

If it ends with an error, run it again: the first run is sometimes slow.

## Step 7: start uploading

```bash
systemctl --user enable --now splatnet3-s3s.service
```

Watch it work:

```bash
journalctl --user -u splatnet3-s3s.service -f
```

After a minute or so you should see `Validating your tokens... done.`, then, if stat.ink
is missing some of your recent battles, lines like:

```text
Battle uploaded to https://stat.ink/@you/spl3/...
```

Press **Ctrl+C** to stop watching (the service keeps running). Your battles are now on
your stat.ink profile, and new ones get there about 5 minutes after each match.

**You're done.** The service starts by itself whenever you log in.

## Everyday use

There is nothing to do. When the tokens expire, the service renews them on its own:
usually with a single request to Nintendo, and every few hours by quietly starting the
hidden phone for about a minute.

Useful commands:

```bash
systemctl --user status splatnet3-s3s.service          # is it running?
journalctl --user -u splatnet3-s3s.service -f          # watch the uploads live
systemctl --user restart splatnet3-s3s.service         # restart it
systemctl --user disable --now splatnet3-s3s.service   # stop uploading for good
```

The service only runs while you are logged in. To keep it running when you log out (on a
server, say):

```bash
loginctl enable-linger "$USER"
```

## Updating

```bash
systemctl --user stop splatnet3-s3s.service
curl -fL https://github.com/Lawkeys-dev/splatnet3-stats-setup/releases/latest/download/splatnet3-stats-setup-linux.tar.gz | tar -xz -C ~/Work
cd ~/Work/splatnet3 && ./install.sh --venv
systemctl --user start splatnet3-s3s.service
```

Your settings, tokens and stat.ink key are kept.

## Something went wrong?

| Symptom | Fix |
|---|---|
| `stu: command not found` | add `~/.local/bin` to your PATH (end of step 2) |
| the phone window never appears | `stu --adb="emu kill"`, then `stu --emu` again. Still nothing: run `stu-sdk emulator -avd NSA` to see the error, often a missing system library |
| *"SplatNet 3 cannot be displayed"* | update **Android System WebView** and **Chrome** in the Play Store (step 5, point 3) |
| the extraction fails 3 times | `stu -im`, and press Enter only once SplatNet 3 is fully on screen |
| no `Battle uploaded` line | check that your stat.ink key is in `template.txt` (step 4), then run `stu -im` again so it is copied over |
| it worked for months, then stopped | the phone's WebView is probably out of date again: `stu --emu`, update it, `stu --adb="emu kill"` |

Still stuck? Look at the log (`journalctl --user -u splatnet3-s3s.service -n 100`): the
last lines usually say what is wrong. The [README](../README.md#troubleshooting) has more
details.
