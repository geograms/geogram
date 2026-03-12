@echo off
setlocal enabledelayedexpansion
title Geogram Dev VM

REM Start the Geogram dev VM using the bundled QEMU binary.
REM No installation required — everything is in this folder.
REM The VM auto-logs in on the serial console.
REM SSH: ssh dev@localhost -p 2222 (password: dev)

set "SCRIPT_DIR=%~dp0"
set "QEMU=%SCRIPT_DIR%bin\windows\qemu-system-x86_64.exe"
set "IMAGE=%SCRIPT_DIR%geogram-dev.qcow2"

REM Check bundled QEMU
if not exist "%QEMU%" (
    echo Bundled QEMU not found at: %QEMU%
    echo The vm\ folder may be incomplete. Re-download from releases.
    echo.
    pause
    exit /b 1
)

REM Check image
if not exist "%IMAGE%" (
    echo VM image not found at: %IMAGE%
    echo The vm\ folder may be incomplete. Re-download from releases.
    echo.
    pause
    exit /b 1
)

set MEMORY=4G
set CPUS=4

REM Detect WHPX (Windows Hypervisor Platform)
set "ACCEL=-accel tcg"
"%QEMU%" -accel help 2>&1 | findstr /c:"whpx" >nul 2>&1
if !errorlevel!==0 (
    set "ACCEL=-accel whpx -cpu max"
    echo [OK] Hardware acceleration: WHPX
) else (
    echo [..] No hardware acceleration. VM will be slower.
    echo     Enable: Settings ^> Apps ^> Optional Features ^> More Windows Features
    echo       ^> check "Windows Hypervisor Platform"
    echo.
)

echo.
echo   Starting VM... ^(close this window to stop^)
echo.

"%QEMU%" ^
    -m %MEMORY% ^
    -smp %CPUS% ^
    %ACCEL% ^
    -drive "file=%IMAGE%,format=qcow2,if=virtio" ^
    -netdev "user,id=net0,hostfwd=tcp::2222-:22" ^
    -device virtio-net-pci,netdev=net0 ^
    -nographic

endlocal
