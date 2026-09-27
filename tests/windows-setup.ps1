<#
End-to-end check of the Windows setup, run by .github/workflows/test.yml on a GitHub runner:
installs from the release zip the way the README does - into a folder with a space in its
path, like C:\Users\Jean Dupont - then exercises the wrappers, supervise.pyw and the
scheduled tasks. Everything short of the emulator itself (no AVD, no Nintendo account).

  powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-setup.ps1 -Zip <release zip>

Keep this file ASCII-only, like install.ps1.
#>
param([Parameter(Mandatory = $true)][string]$Zip)
$ErrorActionPreference = 'Stop'

$script:Failed = $false
function Check([string]$What, [scriptblock]$Condition) {
	try { $ok = [bool](& $Condition) } catch { $ok = $false; $What += " ($($_.Exception.Message))" }
	if ($ok) { Write-Host "PASS  $What" } else { Write-Host "FAIL  $What"; $script:Failed = $true }
}
function Section([string]$Name) { Write-Host ''; Write-Host "=== $Name" }
$Scratch = Join-Path $env:RUNNER_TEMP 'run'
New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
$EmptyStdin = Join-Path $Scratch 'stdin'
$script:RunCount = 0
[System.IO.File]::WriteAllText($EmptyStdin, '')

# a file a leftover process (the adb server) may still hold open for writing
function Read-Shared([string]$Path) {
	$stream = New-Object System.IO.FileStream($Path, 'Open', 'Read', 'ReadWrite')
	try { return (New-Object System.IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
}

# A native command's stdout + stderr as one string, with its exit code in $script:LastRc.
# Output goes through files rather than pipes: a daemon the command leaves behind (the adb
# server) would otherwise hold the pipe open and hang the capture forever. stdin is empty,
# as in the scheduled tasks, and the whole tree is killed after $TimeoutSec.
function Run([string]$Exe, [string[]]$ArgList = @(), [int]$TimeoutSec = 300) {
	$cmd = Get-Command $Exe -ErrorAction SilentlyContinue
	$path = if ($cmd) { $cmd.Path } else { $Exe }
	$quoted = @($ArgList | ForEach-Object { if ($_ -eq '' -or $_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } })
	if ($path -match '\.(cmd|bat)$') {
		$file = $env:ComSpec
		$argLine = '/d /s /c ""' + $path + '" ' + ($quoted -join ' ') + '"'
	} else {
		$file = $path
		$argLine = $quoted -join ' '
	}
	$script:RunCount++
	$out = Join-Path $Scratch "$script:RunCount.out"
	$err = Join-Path $Scratch "$script:RunCount.err"
	Write-Host "   > $Exe $($ArgList -join ' ')"
	$start = @{ FilePath = $file; NoNewWindow = $true; PassThru = $true
		RedirectStandardInput = $EmptyStdin; RedirectStandardOutput = $out; RedirectStandardError = $err }
	if ($argLine) { $start.ArgumentList = $argLine }
	$p = Start-Process @start
	$null = $p.Handle  # keeps ExitCode readable after exit
	$timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
	if ($timedOut) { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null; $p.WaitForExit() }
	$script:LastRc = if ($timedOut) { -1 } else { $p.ExitCode }
	$text = (Read-Shared $out) + "`n" + (Read-Shared $err)
	if ($timedOut) { $text += "`nTIMEOUT after $TimeoutSec s" }
	Write-Host "   < exit code $script:LastRc$(if ($timedOut) { ' (TIMEOUT)' })"
	return $text
}
function Install([string[]]$ArgList = @()) {
	$text = Run 'powershell.exe' (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'install.ps1')) + $ArgList) 900
	Write-Host $text
	return $text
}

Section 'install from the release zip, into a path with a space'
$Base = Join-Path $env:RUNNER_TEMP 'Jean Dupont'
New-Item -ItemType Directory -Force -Path $Base | Out-Null
Expand-Archive -LiteralPath $Zip -DestinationPath $Base -Force
$Root = Join-Path $Base 'splatnet3'
$Stu  = Join-Path $Root 'splatnet3-token-util'
$S3s  = Join-Path $Root 's3s'
$out = Install @('-Venv')
Check 'install.ps1 -Venv exits 0' { $script:LastRc -eq 0 }
Check 'no warning from install.ps1' { $out -notmatch 'WARNING' }

Section 'rendered files'
$files = @('config\config.json', 'config\config-headless.json', 'config\template.txt') | ForEach-Object { Join-Path $Stu $_ }
$files += Join-Path $Stu 'config_run_s3s.json'
foreach ($f in $files) {
	Check "valid JSON: $f" { [System.IO.File]::ReadAllText($f) | ConvertFrom-Json }
	Check "no placeholder left: $f" { [System.IO.File]::ReadAllText($f) -notmatch '__[A-Z_]+__' }
	Check "no BOM: $f" { [System.IO.File]::ReadAllBytes($f)[0] -eq [byte][char]'{' }
}
$cfg = [System.IO.File]::ReadAllText((Join-Path $Stu 'config\config-headless.json')) | ConvertFrom-Json
$run = [System.IO.File]::ReadAllText((Join-Path $Stu 'config_run_s3s.json')) | ConvertFrom-Json
Check "adb_path exists: $($cfg.emulator_config.adb_path)" { Test-Path -LiteralPath $cfg.emulator_config.adb_path }
Check "emulator_path exists: $($cfg.emulator_config.emulator_path)" { Test-Path -LiteralPath $cfg.emulator_config.emulator_path }
Check 's3s_directory is this checkout' { $run.s3s_directory -eq $S3s }
Check 'python_command exists' { Test-Path -LiteralPath $run.python_command }
Check 'pip_command exists' { Test-Path -LiteralPath $run.pip_command }
Check 'pip_command in the stu configs exists' { Test-Path -LiteralPath $cfg.update_config.pip_command }

Section 'user PATH'
$userPath = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
Check 'bin\ is on the user PATH' { ($userPath.Split(';')) -contains (Join-Path $Root 'bin') }

Section 'scheduled tasks'
$Pythonw = Join-Path $Root '.venv\Scripts\pythonw.exe'
foreach ($name in 'splatnet3-s3s', 'splatnet3-tokens') {
	$task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
	Check "$name registered" { $task }
	if (-not $task) { continue }
	Check "$name installed disabled" { $task.State -eq 'Disabled' }
	Check "$name runs pythonw.exe from the venv" { $task.Actions[0].Execute -eq $Pythonw -and (Test-Path -LiteralPath $Pythonw) }
	Check "$name runs supervise.pyw" { $task.Actions[0].Arguments -like "*$Root\bin\supervise.pyw*" }
	Check "$name as the current user, not elevated" { $task.Principal.RunLevel -eq 'Limited' -and $task.Principal.LogonType -eq 'Interactive' }
}
$s3sTask = Get-ScheduledTask -TaskName 'splatnet3-s3s' -ErrorAction SilentlyContinue
if ($s3sTask) {
	Check 'splatnet3-s3s: --restart, -r -M' { $s3sTask.Actions[0].Arguments -like '*--restart*stu-s3s.cmd" -r -M' }
	Check 'splatnet3-s3s: no time limit, at logon' { $s3sTask.Settings.ExecutionTimeLimit -eq 'PT0S' -and $s3sTask.Triggers[0].CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }
}

Section 're-run: idempotent, configs kept, an enabled task stays enabled'
Enable-ScheduledTask -TaskName 'splatnet3-s3s' | Out-Null
$before = (Get-FileHash (Join-Path $Stu 'config\template.txt')).Hash
$out = Install @()
Check 're-run exits 0' { $script:LastRc -eq 0 }
Check 're-run keeps the configs' { $out -match 'kept' }
Check 'template.txt untouched' { (Get-FileHash (Join-Path $Stu 'config\template.txt')).Hash -eq $before }
Check 'splatnet3-s3s still enabled' { (Get-ScheduledTask -TaskName 'splatnet3-s3s').State -ne 'Disabled' }
Check 'splatnet3-tokens still disabled' { (Get-ScheduledTask -TaskName 'splatnet3-tokens').State -eq 'Disabled' }
Disable-ScheduledTask -TaskName 'splatnet3-s3s' | Out-Null

Section 'wrappers, through PATH like in a new terminal'
$env:Path = (Join-Path $Root 'bin') + ';' + $env:Path
$out = Run 'stu' @('--help')
Check 'stu --help' { $out -match 'usage: main.py' }
$out = Run 'stu-s3s' @()
Check 'stu-s3s (s3s --help through s3s-loop.py)' { $out -match 'usage: s3s.py' }
Check 'stu-s3s ran the s3s update with pip.exe' { $out -match [regex]::Escape("Running s3s update with command ``$Root\.venv\Scripts\pip.exe install") }
$out = Run 'stu-s3s-upstream' @('--help')
Check 'stu-s3s-upstream --help' { $out -match 'usage: s3s.py' }
Check 'stu-s3s-upstream: pip found' { $out -notmatch 'is not recognized' }
$out = Run 'stu-sdk' @('adb', 'version')
Check 'stu-sdk adb version' { $out -match 'Android Debug Bridge' }
$out = Run 'stu' @('-u')
Write-Host ($out.Trim().Split("`n") | Select-Object -Last 5 | Out-String)
Check 'stu -u: pip found' { $out -notmatch 'is not recognized' }
Check 'stu -u: dependencies checked' { $out -match 'Requirement already satisfied' }
# stops at the first missing path; there is no AVD on a runner, so it never boots anything
$out = Run 'stu' @('--disable-update-check')
Write-Host $out
Check 'stu: emulator, adb and scripts found (stops at the missing AVD)' { $out -match 'parent directory of snapshot_dir in config does not exist' }
$out = Run 'stu-headless' @()
Check 'stu-headless: same, and fails' { $out -match 'parent directory of snapshot_dir' -and $script:LastRc -ne 0 }
# its emulator check started an adb server: stop it, like the end of a real run would
Run $cfg.emulator_config.adb_path @('kill-server') | Out-Null

Section 'stu copies fresh tokens into s3s'
[System.IO.File]::WriteAllText((Join-Path $Stu 'config.txt'), '{"gtoken": "from-stu"}')
Run 'stu' @('--help') | Out-Null
Check 'stu exits 0 after the copy' { $script:LastRc -eq 0 }
Check 'newer stu tokens copied' { [System.IO.File]::ReadAllText((Join-Path $S3s 'config.txt')) -match 'from-stu' }
Start-Sleep -Seconds 2
[System.IO.File]::WriteAllText((Join-Path $S3s 'config.txt'), '{"gtoken": "from-s3s-loop"}')
Run 'stu' @('--help') | Out-Null
Check 'older stu tokens not copied over newer s3s ones' { [System.IO.File]::ReadAllText((Join-Path $S3s 'config.txt')) -match 'from-s3s-loop' }
# s3s cannot start on these partial files: let it generate a fresh one
Remove-Item -LiteralPath (Join-Path $S3s 'config.txt'), (Join-Path $Stu 'config.txt')

Section 'supervise.pyw, the way the tasks start it'
$Supervise = Join-Path $Root 'bin\supervise.pyw'
$log = Join-Path $Root 'logs\selftest.log'
$p = Start-Process -FilePath $Pythonw -PassThru -WorkingDirectory $Root -ArgumentList ('"{0}" --log "{1}" -- "{2}"' -f $Supervise, $log, (Join-Path $Root 'bin\stu-s3s.cmd'))
Check 'pythonw supervise.pyw finishes' { $p.WaitForExit(300000) }
$text = if (Test-Path -LiteralPath $log) { [System.IO.File]::ReadAllText($log) } else { '' }
Write-Host ($text.Split("`n") | Select-Object -Last 4 | Out-String)
Check 'pythonw supervise.pyw -> stu-s3s.cmd: s3s ran' { $text -match 'usage: s3s.py' }
Check 'pythonw supervise.pyw -> stu-s3s.cmd: exit 0 logged' { $text -match 'exited with code 0' }

Section 'a scheduled task actually runs (informational: needs an interactive logon session)'
$taskLog = Join-Path $Root 'logs\task.log'
$action = New-ScheduledTaskAction -Execute $Pythonw -WorkingDirectory $Root -Argument ('"{0}" --log "{1}" -- "{2}"' -f $Supervise, $taskLog, (Join-Path $Root 'bin\stu-s3s.cmd'))
Set-ScheduledTask -TaskName 'splatnet3-tokens' -Action $action | Out-Null
Enable-ScheduledTask -TaskName 'splatnet3-tokens' | Out-Null
Start-ScheduledTask -TaskName 'splatnet3-tokens'
$deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $deadline -and -not ((Test-Path -LiteralPath $taskLog) -and ([System.IO.File]::ReadAllText($taskLog) -match 'exited with code'))) {
	Start-Sleep -Seconds 5
}
if (Test-Path -LiteralPath $taskLog) {
	$text = [System.IO.File]::ReadAllText($taskLog)
	Write-Host ($text.Split("`n") | Select-Object -Last 3 | Out-String)
	Check 'task ran supervise.pyw -> stu-s3s.cmd to completion' { $text -match 'usage: s3s.py' -and $text -match 'exited with code 0' }
} else {
	$info = Get-ScheduledTaskInfo -TaskName 'splatnet3-tokens'
	Write-Host "INFO  the task did not start on this runner (LastTaskResult $($info.LastTaskResult)); not counted as a failure"
}
Disable-ScheduledTask -TaskName 'splatnet3-tokens' | Out-Null

Section 'Nintendo side: tier 1 with a dead gtoken'
[System.IO.File]::WriteAllText((Join-Path $S3s 'config.txt'),
	'{"api_key": "x", "acc_loc": "en-US|US", "gtoken": "dead", "bullettoken": "dead", "session_token": "skip", "f_gen": "DUMMY_VALUE"}')
$probe = Join-Path $env:RUNNER_TEMP 'tier1.py'
[System.IO.File]::WriteAllText($probe, @'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('loop', sys.argv[1]).load_module()
print('refresh result:', m.refresh_bullettoken(m.load_run_config()))
import iksm
print('web view version:', iksm.WEB_VIEW_VERSION, '(fallback: {})'.format(iksm.WEB_VIEW_VER_FALLBACK))
'@)
Push-Location $Stu
$out = Run $run.python_command @($probe, (Join-Path $Root 'bin\s3s-loop.py'))
Pop-Location
Write-Host $out
Check 'bullet_tokens endpoint rejects a dead gtoken with 401' { $out -match 'Unauthorized error' }
Check 'tier 1 falls through to the emulator' { $out -match 'refresh result: False' }

Section 'SDK under a path with a space (the 8.3 short path fallback)'
$spaced = 'C:\Android Sdk'
$realSdk = Split-Path -Parent (Split-Path -Parent $cfg.emulator_config.adb_path)
New-Item -ItemType Junction -Path $spaced -Target $realSdk | Out-Null
Write-Host (Run 'fsutil' @('8dot3name', 'query', 'C:'))
$short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($spaced).ShortPath
Write-Host "short path of '$spaced': $short"
$out = Install @('-Sdk', $spaced, '-Force')
$adb = ([System.IO.File]::ReadAllText((Join-Path $Stu 'config\config.json')) | ConvertFrom-Json).emulator_config.adb_path
Write-Host "adb_path: $adb"
if ($short.Contains(' ')) {
	Check 'no short name on this volume: install.ps1 warns about it' { $out -match 'has spaces and no 8.3 short name' }
} else {
	Check 'adb_path uses the short path, without spaces' { -not $adb.Contains(' ') -and (Test-Path -LiteralPath $adb) }
	# stu reads this file itself: make sure it accepts the path (it turns spaces into underscores)
	Push-Location $Stu
	$out = Run $run.python_command @('main.py', '--disable-update-check')
	Pop-Location
	Check 'stu accepts the short adb_path' { $out -notmatch 'adb_path in config does not exist' -and $out -notmatch 'emulator_path in config does not exist' }
}

Section 'result'
if ($script:Failed) { Write-Host 'some checks FAILED'; exit 1 }
Write-Host 'all checks passed'
