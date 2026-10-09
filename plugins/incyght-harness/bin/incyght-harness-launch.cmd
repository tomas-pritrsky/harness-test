@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem incyght-harness-launch.cmd (Windows-native, no Git Bash assumed)
rem
rem This IS the stdio MCP command on Windows. stdout must carry the MCP protocol
rem untouched, so all logging goes to stderr (>&2) or %INCYGHT_LOG%. curl.exe does
rem the downloads; PowerShell does JSON parse / hash / expand; then hand stdio to
rem java.exe.
rem
rem Distribution is TWO artifacts: a jlink JRE (harness-runtime-windows-x64.zip ->
rem bin\java.exe) and the per-platform fat JAR (harness-windows-x64-<version>.jar,
rem embedding only the win32_x64 driver). Combined at launch as
rem   <runtime>\bin\java.exe -jar <jar>
rem
rem stdout must stay clean: any echo without >&2 would corrupt the MCP handshake.

rem Windows PowerShell 5.1 inherits PSModulePath from a PowerShell 7 parent (a pwsh
rem terminal puts its own Modules dir first). 5.1 then picks the 7.x
rem Microsoft.PowerShell.Utility module and never defines Get-FileHash, so every
rem checksum fails. Pin the 5.1 module path for the powershell calls below.
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules;%ProgramFiles%\WindowsPowerShell\Modules"

rem Resolve manifest next to this script (bin\..) so it works even if the
rem .mcp.json env block was not applied. Env vars still win when set.
set "MANIFEST=%INCYGHT_MANIFEST%"
if "%MANIFEST%"=="" set "MANIFEST=%~dp0..\manifest.json"
set "DATA=%INCYGHT_DATA%"
if "%DATA%"=="" set "DATA=%CLAUDE_PLUGIN_DATA%"
if "%DATA%"=="" set "DATA=%PLUGIN_DATA%"
if "%DATA%"=="" set "DATA=%LOCALAPPDATA%\incyght-harness"
if "%INCYGHT_LOG%"=="" set "INCYGHT_LOG=%DATA%\harness.log"
if not exist "%MANIFEST%" ( echo [incyght-launch] FATAL manifest not found at %MANIFEST% 1>&2 & exit /b 1 )
if not exist "%DATA%" mkdir "%DATA%" 1>&2

set "PLATFORM=windows-x64"
if /I not "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
  echo [incyght-launch] FATAL unsupported arch %PROCESSOR_ARCHITECTURE% 1>&2
  exit /b 1
)

rem ---- read manifest values via PowerShell -----------------------------------
rem One parse, no pipe: `for /f` mangles an escaped `^|`, which silently blanked
rem every field on Windows. ConvertFrom-Json(Get-Content ...) avoids the pipe and
rem emits KEY=value lines that `set` assigns directly.
for /f "usebackq delims=" %%L in (`powershell -NoProfile -Command "$m=ConvertFrom-Json (Get-Content -Raw '%MANIFEST%'); 'SCHEMA='+$m.manifestSchema; 'VERSION='+$m.harnessVersion; 'BASE='+$m.baseUrl; 'HDR='+$m.auth.header; 'ENVVAR='+$m.auth.envVar; 'JARFILE='+$m.jars.'%PLATFORM%'.file; 'JARSHA='+$m.jars.'%PLATFORM%'.sha256; 'RTFILE='+$m.runtimes.'%PLATFORM%'.file; 'RTSHA='+$m.runtimes.'%PLATFORM%'.sha256"`) do set "%%L"

rem guard: a present-but-unparseable manifest must fail loudly, not fetch '/'
if "%VERSION%"=="" ( echo [incyght-launch] FATAL could not parse manifest %MANIFEST% 1>&2 & exit /b 1 )
if "%BASE%"=="" ( echo [incyght-launch] FATAL manifest has no baseUrl: %MANIFEST% 1>&2 & exit /b 1 )
if not "%SCHEMA%"=="2" ( echo [incyght-launch] FATAL manifest schema %SCHEMA% newer than this launcher understands - update the plugin 1>&2 & exit /b 1 )
if "%JARFILE%"=="" ( echo [incyght-launch] FATAL manifest has no jar file for %PLATFORM% 1>&2 & exit /b 1 )

set "BASE_CACHE=%DATA%\harness\%VERSION%"
set "JAR_PATH=%BASE_CACHE%\%JARFILE%"
set "RUNTIME_DIR=%BASE_CACHE%\%PLATFORM%\harness-runtime"
set "JAVA=%RUNTIME_DIR%\bin\java.exe"
call set "TOKEN=%%%ENVVAR%%%"

rem ---- provision the JAR ------------------------------------------------------
if not exist "%JAR_PATH%" (
  call :fetch_verify "%JARFILE%" "%JAR_PATH%" "%JARSHA%" || exit /b 1
)

rem ---- provision the runtime (or fall back to system java) --------------------
if not exist "%JAVA%" (
  if "%RTFILE%"=="" (
    where java >nul 2>&1 || ( echo [incyght-launch] FATAL no runtime + no system java 1>&2 & exit /b 1 )
    set "JAVA=java"
  ) else (
    set "ARCHIVE=%DATA%\.dl.%RANDOM%.%RTFILE%"
    call :fetch_verify "%RTFILE%" "!ARCHIVE!" "%RTSHA%" || exit /b 1
    powershell -NoProfile -Command "Expand-Archive -Path '!ARCHIVE!' -DestinationPath '%BASE_CACHE%\%PLATFORM%' -Force" 1>>"%INCYGHT_LOG%" 2>&1
    del /q "!ARCHIVE!" 2>nul
    if not exist "%JAVA%" ( echo [incyght-launch] FATAL runtime extracted but java.exe missing 1>&2 & exit /b 1 )
    echo [incyght-launch] runtime installed to %RUNTIME_DIR% 1>&2
  )
)

if /I "%~1"=="--prefetch" (
  echo [incyght-launch] prefetch complete 1>&2
  exit /b 0
)

"%JAVA%" -jar "%JAR_PATH%"
exit /b %ERRORLEVEL%

rem ---- :fetch_verify <remote-file> <dest-path> <want-sha256> ------------------
:fetch_verify
setlocal
set "F=%~1" & set "DEST=%~2" & set "WANT=%~3"
rem a gated network host needs the token; a local file:// host (dev/demo) does not
if /I "%BASE:~0,4%"=="http" if not "%HDR%"=="" if "%TOKEN%"=="" ( echo [incyght-launch] FATAL access token not set - configure incyght_token 1>&2 & endlocal & exit /b 1 )
set "TMP=%DATA%\dl-%RANDOM%.tmp"
echo [incyght-launch] fetching %F% 1>&2
rem curl.exe (bundled since Win10 1803) streams straight to disk; Invoke-WebRequest
rem buffers the whole file in memory and its -OutFile write can be denied. Send the
rem auth header only when set.
if not "%HDR%"=="" (
  curl.exe -fsSL -H "%HDR%: %TOKEN%" -o "%TMP%" "%BASE%/%F%" 1>>"%INCYGHT_LOG%" 2>&1
) else (
  curl.exe -fsSL -o "%TMP%" "%BASE%/%F%" 1>>"%INCYGHT_LOG%" 2>&1
)
if errorlevel 1 ( echo [incyght-launch] FATAL download failed for %F% 1>&2 & del /q "%TMP%" 2>nul & endlocal & exit /b 1 )
set "GOT="
for /f "usebackq delims=" %%G in (`powershell -NoProfile -Command "(Get-FileHash '%TMP%' -Algorithm SHA256).Hash.ToLower()"`) do set "GOT=%%G"
if /I not "%GOT%"=="%WANT%" ( echo [incyght-launch] FATAL checksum mismatch for %F% 1>&2 & del /q "%TMP%" 2>nul & endlocal & exit /b 1 )
for %%D in ("%DEST%") do if not exist "%%~dpD" mkdir "%%~dpD" 1>&2
move /y "%TMP%" "%DEST%" 1>&2
echo [incyght-launch] verified %F% 1>&2
endlocal & exit /b 0
