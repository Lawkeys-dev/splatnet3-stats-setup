@echo off
rem splatnet3-token-util wrapper (windowed / interactive).
rem Passes all arguments through to main.py.
rem   stu                 -> extract tokens (emulator window visible)
rem   stu -im             -> interactive mode (press Enter when SplatNet3 is loaded)
rem   stu --emu           -> just boot the emulator (for manual setup/login)
rem   stu --adb="devices" -> run an adb command against the emulator
setlocal
if not defined ANDROID_HOME set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"
set "PATH=%ANDROID_HOME%\platform-tools;%ANDROID_HOME%\emulator;%PATH%"
set "PYTHONUTF8=1"
rem the checkout is the parent of this script's directory (bin is on the user PATH)
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
cd /d "%ROOT%\splatnet3-token-util" || exit /b 1
"%ROOT%\.venv\Scripts\python.exe" main.py %*
exit /b %ERRORLEVEL%
