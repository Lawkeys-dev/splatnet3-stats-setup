@echo off
rem splatnet3-token-util token refresh, no emulator window. Used by the splatnet3-tokens task.
rem Writes fresh tokens to splatnet3-token-util\config.txt and copies them into the
rem s3s directory so s3s always has valid tokens.
setlocal
if not defined ANDROID_HOME set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"
set "PATH=%ANDROID_HOME%\platform-tools;%ANDROID_HOME%\emulator;%PATH%"
set "PYTHONUTF8=1"
rem the checkout is the parent of this script's directory (bin is on the user PATH)
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
cd /d "%ROOT%\splatnet3-token-util" || exit /b 1
rem Task Scheduler has no Conflicts=, and splatnet3-token-util cannot cope with two
rem emulators at once: refuse to boot a second one
adb devices 2>nul | findstr /b "emulator-" >nul && (
	echo an emulator is already running ^(the s3s task or a manual stu run^) - not starting a second one
	exit /b 1
)
"%ROOT%\.venv\Scripts\python.exe" main.py --config ./config/config-headless.json --disable-update-check %*
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
copy /y config.txt "%ROOT%\s3s\config.txt" >nul || exit /b 1
echo tokens refreshed -^> %ROOT%\splatnet3-token-util\config.txt and %ROOT%\s3s\config.txt
