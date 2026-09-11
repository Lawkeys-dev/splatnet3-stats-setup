<#
Installs this setup for the current Windows user:
  - clones s3s and splatnet3-token-util next to this repo (if missing)
  - renders the config files from config\windows\*.example and config\template.txt.example
  - puts bin\ on the user PATH
  - registers the scheduled tasks (without enabling them)

Nothing is overwritten unless -Force is passed. Idempotent: safe to re-run.

  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1            # install / repair
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Force     # also overwrite existing config files
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Venv      # additionally create the shared venv with uv
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Sdk D:\Android\Sdk

Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts in the
ANSI code page.
#>
param(
	[switch]$Force,
	[switch]$Venv,
	# Android SDK location; default: ANDROID_HOME, else where Android Studio puts it
	[string]$Sdk
)
$ErrorActionPreference = 'Stop'

$Root    = $PSScriptRoot
$Stu     = Join-Path $Root 'splatnet3-token-util'
$S3s     = Join-Path $Root 's3s'
$VenvDir = Join-Path $Root '.venv'
$BinDir  = Join-Path $Root 'bin'
$LogDir  = Join-Path $Root 'logs'

# what the bin\*.cmd wrappers use when ANDROID_HOME is not set
$DefaultSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$WrapperSdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { $DefaultSdk }
if (-not $Sdk) { $Sdk = $WrapperSdk }
$Sdk = $Sdk.TrimEnd('\')
$AvdHome = if ($env:ANDROID_AVD_HOME) { $env:ANDROID_AVD_HOME } else { Join-Path $env:USERPROFILE '.android\avd' }

# splatnet3-token-util turns every space in adb_path into an underscore, so a
# profile like C:\Users\Jean Dupont breaks it; the 8.3 short path has no spaces
$SdkForConfig = $Sdk
if ($Sdk.Contains(' ') -and (Test-Path -LiteralPath $Sdk)) {
	$SdkForConfig = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($Sdk).ShortPath
}

function Say([string]$Message) {
	Write-Host ''
	Write-Host "== $Message"
}

# git and uv report progress on stderr, which some hosts turn into a terminating
# error under 'Stop'; native commands are judged by their exit code instead
function Invoke-Native([string]$Exe, [string[]]$ArgList) {
	$ErrorActionPreference = 'Continue'
	& $Exe @ArgList
	if ($LASTEXITCODE -ne 0) { throw "$Exe $($ArgList -join ' ') failed (exit code $LASTEXITCODE)" }
}

# the placeholders sit inside JSON strings: backslashes and quotes must be escaped
function ConvertTo-JsonText([string]$Text) {
	$Text.Replace('\', '\\').Replace('"', '\"')
}

$Placeholders = @{
	'__ROOT__'     = ConvertTo-JsonText $Root
	'__SDK__'      = ConvertTo-JsonText $SdkForConfig
	'__AVD_HOME__' = ConvertTo-JsonText $AvdHome
}
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Install-File([string]$Src, [string]$Dst) {
	if ((Test-Path -LiteralPath $Dst) -and -not $Force) {
		Write-Host "   kept   $Dst (exists; -Force to overwrite)"
		return
	}
	$text = [System.IO.File]::ReadAllText($Src)
	foreach ($name in $Placeholders.Keys) { $text = $text.Replace($name, $Placeholders[$name]) }
	# no BOM: Python's json module refuses one
	[System.IO.File]::WriteAllText($Dst, $text, $Utf8NoBom)
	Write-Host "   wrote  $Dst"
}

Say 'upstream projects'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
	throw 'git not found: install Git for Windows (https://git-scm.com/download/win)'
}
if (-not (Test-Path -LiteralPath (Join-Path $S3s '.git'))) {
	Invoke-Native git @('clone', 'https://github.com/frozenpandaman/s3s.git', $S3s)
}
if (-not (Test-Path -LiteralPath (Join-Path $Stu '.git'))) {
	Invoke-Native git @('clone', 'https://github.com/strohitv/splatnet3-token-util.git', $Stu)
}
Write-Host "   $S3s"
Write-Host "   $Stu"

Say 'config files'
New-Item -ItemType Directory -Force -Path (Join-Path $Stu 'config') | Out-Null
Install-File (Join-Path $Root 'config\windows\config.json.example')          (Join-Path $Stu 'config\config.json')
Install-File (Join-Path $Root 'config\windows\config-headless.json.example') (Join-Path $Stu 'config\config-headless.json')
Install-File (Join-Path $Root 'config\template.txt.example')                 (Join-Path $Stu 'config\template.txt')
Install-File (Join-Path $Root 'config\windows\config_run_s3s.json.example')  (Join-Path $Stu 'config_run_s3s.json')

Say "wrapper scripts: $BinDir -> user PATH"
$envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
try {
	# the raw value, so entries like %USERPROFILE%\... are written back unexpanded
	$userPath = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
	$entries = @($userPath.Split(';') | Where-Object { $_ })
	$pathChanged = $entries -notcontains $BinDir
	if ($pathChanged) {
		$envKey.SetValue('Path', (($entries + $BinDir) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
	}
} finally {
	$envKey.Close()
}
if ($pathChanged) {
	# tell Explorer, so terminals opened from now on get the new PATH
	Add-Type -Namespace SplatNet3 -Name User32 -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
	$result = [UIntPtr]::Zero
	# HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG
	[void][SplatNet3.User32]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
	Write-Host '   added (open a new terminal to use it)'
} else {
	Write-Host '   already on PATH'
}

Say 'scheduled tasks'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Pythonw   = Join-Path $VenvDir 'Scripts\pythonw.exe'
$Supervise = Join-Path $BinDir 'supervise.pyw'
$User      = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
# run as you, only while you are logged on: no password stored, no elevation
$Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited

function Register-Task([string]$Name, [string]$Description, [string]$Arguments, $Trigger, [TimeSpan]$TimeLimit) {
	# installed disabled, like the systemd units; a re-run keeps a task you enabled
	$existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
	$enabled = [bool]($existing -and $existing.State -ne 'Disabled')
	$settings = @{
		AllowStartIfOnBatteries    = $true
		DontStopIfGoingOnBatteries = $true
		MultipleInstances          = 'IgnoreNew'
		ExecutionTimeLimit         = $TimeLimit
		Compatibility              = 'Win8'
		Disable                    = -not $enabled
	}
	$task = @{
		TaskName    = $Name
		Description = $Description
		Action      = New-ScheduledTaskAction -Execute $Pythonw -Argument $Arguments -WorkingDirectory $Root
		Trigger     = $Trigger
		Principal   = $Principal
		Settings    = New-ScheduledTaskSettingsSet @settings
		Force       = $true
	}
	Register-ScheduledTask @task | Out-Null
	Write-Host ('   {0} ({1})' -f $Name, $(if ($enabled) { 'enabled' } else { 'disabled' }))
}

# at logon, a minute late so the network is up (After=network-online.target)
$AtLogon = New-ScheduledTaskTrigger -AtLogOn -User $User
$AtLogon.Delay = 'PT1M'
# first run in a few minutes, then once an hour
$Hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) -RepetitionInterval (New-TimeSpan -Hours 1)

$S3sArgs    = '"{0}" --restart --log "{1}" -- "{2}" -r -M' -f $Supervise, (Join-Path $LogDir 's3s.log'), (Join-Path $BinDir 'stu-s3s.cmd')
$TokensArgs = '"{0}" --log "{1}" -- "{2}"' -f $Supervise, (Join-Path $LogDir 'tokens.log'), (Join-Path $BinDir 'stu-headless.cmd')
try {
	Register-Task 'splatnet3-s3s' 's3s stat.ink uploader (monitoring mode, auto token refresh)' $S3sArgs $AtLogon ([TimeSpan]::Zero)
	# the run itself is capped at 50 min by max_run_duration_minutes in config-headless.json
	Register-Task 'splatnet3-tokens' 'Hourly SplatNet 3 token refresh (splatnet3-token-util, headless)' $TokensArgs $Hourly (New-TimeSpan -Minutes 65)
} catch {
	Write-Warning "could not register the scheduled tasks: $($_.Exception.Message)"
	Write-Warning 'on "Access is denied", re-run from an elevated PowerShell; the tasks still run as you, not elevated'
}

if ($Venv) {
	Say "shared venv -> $VenvDir"
	if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { throw 'uv not found: https://docs.astral.sh/uv/' }
	if (-not (Test-Path -LiteralPath $VenvDir)) { Invoke-Native uv @('venv', '--python', '3.12', $VenvDir) }
	Invoke-Native uv @('pip', 'install', '--python', (Join-Path $VenvDir 'Scripts\python.exe'),
		'-r', (Join-Path $Stu 'requirements.txt'), '-r', (Join-Path $S3s 'requirements.txt'))
}

if (-not (Test-Path -LiteralPath (Join-Path $Sdk 'platform-tools\adb.exe'))) {
	Write-Warning "no Android SDK at $Sdk yet: install it (see README), or re-run with -Sdk <path> -Force"
} elseif ($SdkForConfig.Contains(' ')) {
	Write-Warning "$Sdk has spaces and no 8.3 short name, so splatnet3-token-util will not find adb: move the SDK to a path without spaces (e.g. C:\Android\Sdk) and re-run with -Sdk C:\Android\Sdk -Force"
}
if ($Sdk -ne $WrapperSdk.TrimEnd('\')) {
	Write-Warning "set the user environment variable ANDROID_HOME=$Sdk so the bin\ wrappers use this SDK too"
}

Write-Host @"

== done. remaining manual steps:

 1. venv (skipped unless -Venv):
      uv venv --python 3.12 "$VenvDir"
      uv pip install --python "$VenvDir\Scripts\python.exe" -r "$Stu\requirements.txt" -r "$S3s\requirements.txt"

 2. an AVD named NSA (Pixel 4, API 30, Google Play; see README), then log into the
    Nintendo Switch Online app inside it - from a new terminal, so bin\ is on PATH:
      stu --emu

 3. put your stat.ink API token in $Stu\config\template.txt

 4. first token extraction, then start uploading:
      stu -im
      Enable-ScheduledTask splatnet3-s3s; Start-ScheduledTask splatnet3-s3s
"@
