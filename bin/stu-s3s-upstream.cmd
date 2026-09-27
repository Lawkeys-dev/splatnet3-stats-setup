@echo off
rem splatnet3-token-util's own run_s3s.py loop: every token expiry boots the emulator.
rem Kept as a fallback; the normal entry point is stu-s3s.
setlocal
if not defined ANDROID_HOME set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"
set "PATH=%ANDROID_HOME%\platform-tools;%ANDROID_HOME%\emulator;%PATH%"
set "PYTHONUTF8=1"
rem the checkout is the parent of this script's directory (bin is on the user PATH)
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
cd /d "%ROOT%\splatnet3-token-util" || exit /b 1
"%ROOT%\.venv\Scripts\python.exe" run_s3s.py %*
exit /b %ERRORLEVEL%
