@echo off
setlocal enabledelayedexpansion
rem Launches Reach. Finds the winget-installed Godot 4.x, falls back to PATH.

set "GODOT=%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7-stable_win64.exe"

if not exist "%GODOT%" (
    rem Version may have changed ? take any Godot exe in the winget package dir.
    for /r "%LOCALAPPDATA%\Microsoft\WinGet\Packages" %%f in (Godot_v4*win64.exe) do (
        echo %%~nf | findstr /i "console" >nul || set "GODOT=%%f"
    )
)

if not exist "!GODOT!" (
    for /f "delims=" %%i in ('where godot 2^>nul') do set "GODOT=%%i"
)

if not exist "!GODOT!" (
    echo Godot not found. Install it with:
    echo   winget install GodotEngine.GodotEngine
    pause
    exit /b 1
)

start "" "!GODOT!" --path "%~dp0desktop"
