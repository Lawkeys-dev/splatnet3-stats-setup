#!/usr/bin/env bash
# End-to-end check of the Linux setup, run by .github/workflows/test.yml on a GitHub runner:
# installs from the release tarball the way the README does, then exercises the wrappers.
# Everything short of the emulator itself (no AVD, no Nintendo account on a runner).
#
#   tests/linux-setup.sh <release tarball>
set -euo pipefail

TARBALL="$(readlink -f "$1")"
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { # description, command...
	local what="$1"; shift
	if "$@"; then pass "$what"; else fail "$what"; fi
}
has()  { grep -q -- "$1" <<<"$2"; }   # pattern, text
lacks() { ! grep -q -- "$1" <<<"$2"; }
section() { printf '\n=== %s\n' "$1"; }

section "install from the release tarball"
mkdir -p ~/Work
tar -xzf "$TARBALL" -C ~/Work
ROOT="$HOME/Work/splatnet3"
STU="$ROOT/splatnet3-token-util"
cd "$ROOT"
./install.sh --venv
export PATH="$HOME/.local/bin:$PATH"
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
SDK="${SDK%/}"

section "rendered files"
for f in "$STU/config/config.json" "$STU/config/config-headless.json" "$STU/config/template.txt" "$STU/config_run_s3s.json"; do
	check "valid JSON: ${f#"$ROOT"/}" python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$f"
	check "no placeholder left: ${f#"$ROOT"/}" lacks '__[A-Z_]*__' "$(cat "$f")"
done
json() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))$2)" "$1"; }
check "adb_path exists"        test -x "$(json "$STU/config/config-headless.json" "['emulator_config']['adb_path']")"
check "adb_path is ANDROID_HOME's" test "$(json "$STU/config/config.json" "['emulator_config']['adb_path']")" = "$SDK/platform-tools/adb"
check "python_command exists"  test -x "$(json "$STU/config_run_s3s.json" "['python_command']")"
check "pip_command exists"     test -x "$(json "$STU/config_run_s3s.json" "['pip_command']")"
check "s3s_directory exists"   test -d "$(json "$STU/config_run_s3s.json" "['s3s_directory']")"
for s in stu stu-headless stu-s3s stu-s3s-upstream stu-sdk; do
	check ".local/bin/$s -> bin/$s" test "$(readlink -f "$HOME/.local/bin/$s")" = "$ROOT/bin/$s"
done

section "systemd units"
UNITS="$HOME/.config/systemd/user"
for u in splatnet3-s3s.service splatnet3-tokens.service splatnet3-tokens.timer; do
	check "installed: $u" test -f "$UNITS/$u"
done
# %h/Work/splatnet3 is left as is when the checkout is there
unit="$(sed "s|%h|$HOME|g" "$UNITS/splatnet3-s3s.service")"
exec_start="$(grep '^ExecStart=' <<<"$unit")"
check "ExecStart points at this checkout" test "$exec_start" = "ExecStart=$ROOT/bin/stu-s3s -r -M"
check "ExecStopPost uses ANDROID_HOME's adb" has "ADB=$SDK/platform-tools/adb;" "$unit"
if [ "$SDK" != "$HOME/Android/Sdk" ]; then
	check "units pass ANDROID_HOME on" has "^Environment=\"ANDROID_HOME=$SDK\"\$" "$unit"
fi
verify_out="$(systemd-analyze verify --user "$UNITS"/splatnet3-* 2>&1 || true)"
echo "$verify_out" | grep -i splatnet3 || true
echo "$verify_out" | tail -5
check "systemd-analyze verify: nothing about our units" lacks "splatnet3-" "$verify_out"

section "re-run: idempotent, configs kept"
before="$(sha256sum "$STU/config/template.txt")"
rerun="$(./install.sh 2>&1)"
check "re-run keeps the configs" has "kept   $STU/config/template.txt" "$rerun"
check "template.txt untouched" test "$(sha256sum "$STU/config/template.txt")" = "$before"

section "wrappers"
out="$(stu --help 2>&1 || true)"
check "stu --help" has "usage: main.py" "$out"
out="$(stu-s3s </dev/null 2>&1 || true)"
check "stu-s3s (s3s --help through s3s-loop.py)" has "usage: s3s.py" "$out"
check "stu-s3s ran the s3s update with pip" has "Running s3s update with command \`$ROOT/.venv/bin/pip install" "$out"
out="$(stu-s3s-upstream --help </dev/null 2>&1 || true)"
check "stu-s3s-upstream --help" has "usage: s3s.py" "$out"
check "stu-s3s-upstream: pip found" lacks "pip: not found" "$out"
out="$(stu-sdk adb version 2>&1 || true)"
check "stu-sdk adb version" has "Android Debug Bridge" "$out"
out="$(stu -u 2>&1 || true)"
echo "$out" | tail -5
check "stu -u: pip found" lacks "pip: not found" "$out"
check "stu -u: dependencies checked" has "Requirement already satisfied" "$out"
if [ ! -x "$SDK/emulator/emulator" ]; then
	# the runner's SDK has no emulator package: fetch it the way the README does
	stu-sdk sdkmanager --install emulator </dev/null >/dev/null || true
fi
check "stu-sdk sdkmanager: emulator package present" test -x "$SDK/emulator/emulator"
# stops at the first missing path; there is no AVD on a runner, so it never boots anything
out="$(timeout 300 stu --disable-update-check 2>&1 || true)"
echo "$out" | tail -2
check "stu: emulator, adb and scripts found (stops at the missing AVD)" has "parent directory of snapshot_dir in config does not exist" "$out"

section "stu copies fresh tokens into s3s"
echo '{"gtoken": "from-stu"}' > "$STU/config.txt"
stu --help >/dev/null
check "newer stu tokens copied" grep -q from-stu "$ROOT/s3s/config.txt"
sleep 1
echo '{"gtoken": "from-s3s-loop"}' > "$ROOT/s3s/config.txt"
stu --help >/dev/null
check "older stu tokens not copied over newer s3s ones" grep -q from-s3s-loop "$ROOT/s3s/config.txt"
# s3s cannot start on these partial files: let it generate a fresh one
rm -f "$ROOT/s3s/config.txt" "$STU/config.txt"

section "Nintendo side: tier 1 with a dead gtoken"
cat > "$ROOT/s3s/config.txt" <<'EOF'
{"api_key": "x", "acc_loc": "en-US|US", "gtoken": "dead", "bullettoken": "dead", "session_token": "skip", "f_gen": "DUMMY_VALUE"}
EOF
out="$(cd "$STU" && "$ROOT/.venv/bin/python" - "$ROOT/bin/s3s-loop.py" <<'EOF' 2>&1
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('loop', sys.argv[1]).load_module()
print('refresh result:', m.refresh_bullettoken(m.load_run_config()))
import iksm
print('web view version:', iksm.WEB_VIEW_VERSION, '(fallback: {})'.format(iksm.WEB_VIEW_VER_FALLBACK))
EOF
)" || true
echo "$out"
check "bullet_tokens endpoint rejects a dead gtoken with 401" has "Unauthorized error" "$out"
check "tier 1 falls through to the emulator" has "refresh result: False" "$out"

section "result"
if [ "$FAILED" -ne 0 ]; then echo "some checks FAILED"; exit 1; fi
echo "all checks passed"
