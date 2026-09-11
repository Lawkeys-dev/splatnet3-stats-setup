@echo off
rem s3s wrapper: runs s3s and refreshes the SplatNet 3 tokens only when they are actually dead.
rem On RC 42 it first tries to mint a new bulletToken from the stored gtoken (one HTTPS
rem call, no emulator); the emulator extraction only runs when the gtoken is gone too.
rem   stu-s3s --getseed   -> export gear file for Lean's Gear Seed Checker
rem   stu-s3s -r          -> upload recent battles to stat.ink (needs api_key in config\template.txt)
rem   stu-s3s -r -M       -> upload + monitoring mode
rem   stu-s3s -r -M -im   -> same, but token extraction runs windowed/interactive
rem The upstream loop without the cheap tier is still available: stu-s3s-upstream.
setlocal
if not defined ANDROID_HOME set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"
set "PATH=%ANDROID_HOME%\platform-tools;%ANDROID_HOME%\emulator;%PATH%"
set "PYTHONUTF8=1"
rem the checkout is the parent of this script's directory (bin is on the user PATH)
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
cd /d "%ROOT%\splatnet3-token-util" || exit /b 1
"%ROOT%\.venv\Scripts\python.exe" "%ROOT%\bin\s3s-loop.py" %*
exit /b %ERRORLEVEL%
