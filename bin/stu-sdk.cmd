@echo off
rem Android SDK manager helpers (sdkmanager / avdmanager) with a JDK in JAVA_HOME.
rem   stu-sdk sdkmanager --list
rem   stu-sdk avdmanager list avd
setlocal
rem sdkmanager/avdmanager need a JDK; use JAVA_HOME, else the one bundled with Android Studio
if not defined JAVA_HOME if exist "%ProgramFiles%\Android\Android Studio\jbr\bin\java.exe" set "JAVA_HOME=%ProgramFiles%\Android\Android Studio\jbr"
if defined JAVA_HOME set "PATH=%JAVA_HOME%\bin;%PATH%"
if not defined ANDROID_HOME set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"
set "PATH=%ANDROID_HOME%\cmdline-tools\latest\bin;%ANDROID_HOME%\platform-tools;%ANDROID_HOME%\emulator;%PATH%"
%*
exit /b %ERRORLEVEL%
