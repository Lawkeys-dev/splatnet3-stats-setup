#!/usr/bin/env bash
# Installs this setup into $HOME:
#   - clones s3s and splatnet3-token-util next to this repo (if missing)
#   - renders the config files from config/linux/*.example and config/template.txt.example
#   - symlinks bin/* into ~/.local/bin
#   - installs the systemd user units (without enabling them)
#
# Nothing is overwritten unless --force is passed. Idempotent: safe to re-run.
#
#   ./install.sh              # install / repair
#   ./install.sh --force      # also overwrite existing config files
#   ./install.sh --venv       # additionally create the shared venv with uv
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STU="$ROOT/splatnet3-token-util"
S3S="$ROOT/s3s"
VENV="$ROOT/.venv"
BIN_DIR="${HOME}/.local/bin"
UNIT_DIR="${HOME}/.config/systemd/user"
# Android SDK: ANDROID_HOME if set (the bin/ wrappers honour it too), else the Android Studio default
DEFAULT_SDK="${HOME}/Android/Sdk"
SDK="${ANDROID_HOME:-$DEFAULT_SDK}"
SDK="${SDK%/}"

FORCE=0
MAKE_VENV=0
for arg in "$@"; do
	case "$arg" in
		--force) FORCE=1 ;;
		--venv)  MAKE_VENV=1 ;;
		*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

say() { printf '\n== %s\n' "$1"; }

install_file() { # src dst
	if [ -e "$2" ] && [ "$FORCE" -eq 0 ]; then
		echo "   kept   $2 (exists; --force to overwrite)"
		return
	fi
	sed -e "s|__ROOT__|${ROOT}|g" -e "s|__HOME__/Android/Sdk|${SDK}|g" -e "s|__HOME__|${HOME}|g" "$1" > "$2"
	echo "   wrote  $2"
}

say "upstream projects"
[ -d "$S3S/.git" ] || git clone https://github.com/frozenpandaman/s3s.git "$S3S"
[ -d "$STU/.git" ] || git clone https://github.com/strohitv/splatnet3-token-util.git "$STU"
echo "   $S3S"
echo "   $STU"

say "config files"
mkdir -p "$STU/config"
install_file "$ROOT/config/linux/config.json.example"          "$STU/config/config.json"
install_file "$ROOT/config/linux/config-headless.json.example" "$STU/config/config-headless.json"
install_file "$ROOT/config/template.txt.example"               "$STU/config/template.txt"
install_file "$ROOT/config/linux/config_run_s3s.json.example"  "$STU/config_run_s3s.json"

say "wrapper scripts -> $BIN_DIR"
mkdir -p "$BIN_DIR"
for script in stu stu-headless stu-s3s stu-s3s-upstream stu-sdk; do
	ln -sfn "$ROOT/bin/$script" "$BIN_DIR/$script"
	echo "   $BIN_DIR/$script"
done

say "systemd user units -> $UNIT_DIR"
mkdir -p "$UNIT_DIR"
# the units address the checkout as %h/Work/splatnet3 and the SDK as %h/Android/Sdk;
# point them at this checkout / ANDROID_HOME if they live elsewhere
unit_sed=(-e "")  # no-op, so sed always gets a script
[ "$ROOT" = "$HOME/Work/splatnet3" ] || unit_sed+=(-e "s|%h/Work/splatnet3|${ROOT}|g")
if [ "$SDK" != "$DEFAULT_SDK" ]; then
	# systemd does not see the shell's ANDROID_HOME: hand it to the wrappers explicitly
	unit_sed+=(-e "s|%h/Android/Sdk|${SDK}|g" -e "/^\[Service\]\$/a Environment=\"ANDROID_HOME=${SDK}\"")
fi
for unit in "$ROOT"/systemd/*.service "$ROOT"/systemd/*.timer; do
	sed "${unit_sed[@]}" "$unit" > "$UNIT_DIR/$(basename "$unit")"
	echo "   $(basename "$unit")"
done
systemctl --user daemon-reload 2>/dev/null || echo "   (no systemd user session - skipped daemon-reload)"

if [ "$MAKE_VENV" -eq 1 ]; then
	say "shared venv -> $VENV"
	command -v uv >/dev/null || { echo "uv not found: https://docs.astral.sh/uv/" >&2; exit 1; }
	[ -d "$VENV" ] || uv venv --python 3.12 "$VENV"
	# pip too: a uv venv has none, and the configs' pip_command (stu's update, run_s3s.py) needs it
	uv pip install --python "$VENV/bin/python" pip -r "$STU/requirements.txt" -r "$S3S/requirements.txt"
fi

cat <<NEXT

== done. remaining manual steps:

 1. venv (skipped unless --venv):
      uv venv --python 3.12 "$VENV"
      uv pip install --python "$VENV/bin/python" pip -r "$STU/requirements.txt" -r "$S3S/requirements.txt"

 2. Android SDK + an AVD named NSA (Play Store image, see README), then log into
    the Nintendo Switch Online app inside it:
      stu --emu

 3. put your stat.ink API token in $STU/config/template.txt

 4. first token extraction, then start uploading:
      stu -im
      systemctl --user enable --now splatnet3-s3s.service
NEXT
