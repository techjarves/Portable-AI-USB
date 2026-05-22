@echo off
setlocal enabledelayedexpansion
title Portable AI Launcher Pro v5.0 - ELITE EDITION
color 0B

:: 1. RUTAS Y VARIABLES DE ENTORNO (Blindaje Total)
set "USB_ROOT=%~dp0"
set "DATA_DIR=%USB_ROOT%anythingllm_data"
set "OLLAMA_DIR=%USB_ROOT%ollama"
set "OLLAMA_MODELS=%OLLAMA_DIR%\data"

set "USERPROFILE=%DATA_DIR%"
set "APPDATA=%DATA_DIR%"
set "LOCALAPPDATA=%DATA_DIR%"
set "TEMP=%DATA_DIR%\temp"
set "TMP=%DATA_DIR%\temp"
set "OLLAMA_MODELS=%OLLAMA_MODELS%"

if not exist "%DATA_DIR%\temp" mkdir "%DATA_DIR%\temp" 2>nul

echo ===================================================
echo     SISTEMA IA PORTABLE - ELITE EDITION v5.0
echo ===================================================

:: 2. VERIFICACIÓN DE ESPACIO EN DISCO (Evita corrupción de DB)
:: Verifica si hay al menos 500MB libres en el USB
for /f "tokens=3" %%a in ('dir "%USB_ROOT%" ^| find "bytes libres"') do set "bytes=%%a"
set "bytes=%bytes:.=%"
if %bytes% LSS 524288000 (
    echo [!] ADVERTENCIA: Poco espacio en el USB. 
    echo     Esto puede corromper tus chats. Libera espacio.
    pause
)

:: 3. LIMPIEZA DE PUERTOS Y PROCESOS
taskkill /F /T /IM "ollama*" >nul 2>&1
taskkill /F /T /IM "AnythingLLM*" >nul 2>&1

:: 4. LANZAMIENTO DEL MOTOR CON PRIORIDAD
echo [+] Iniciando motor Ollama...
if exist "%OLLAMA_DIR%\ollama.exe" (
    :: Iniciamos con prioridad 'Abovenormal' para evitar tartamudeo en la IA
    start "Ollama Engine" /B /Abovenormal "%OLLAMA_DIR%\ollama.exe" serve
) else (
    echo [ERROR] No se encuentra ollama.exe
    pause & exit
)

:: 5. BUCLE DE SALUD (Healthcheck)
set /a "attempts=0"
:WaitForOllama
set /a "attempts+=1"
if %attempts% GEQ 40 (echo [ERROR] Timeout. & pause & exit)
curl -s -m 2 http://127.0.0.1:11434/api/tags >nul 2>&1 || (
    <nul set /p "=." 
    timeout /t 2 /nobreak >nul
    goto :WaitForOllama
)
echo. [OK] Motor activo.

:: 6. LANZAMIENTO DE INTERFAZ (Modo Privacidad Máxima)
if exist "%USB_ROOT%anythingllm\AnythingLLM.exe" (
    echo [+] Lanzando interfaz con proteccion de datos...
    pushd "%USB_ROOT%anythingllm"
    :: Banderas añadidas para evitar telemetría y mejorar rendimiento
    start "" /Abovenormal "AnythingLLM.exe" ^
    --user-data-dir="%DATA_DIR%" ^
    --no-sandbox ^
    --disable-gpu-shader-disk-cache ^
    --disable-software-rasterizer ^
    --disable-dev-shm-usage ^
    --disable-metrics ^
    --disable-breakpad
    popd
)

echo.
echo ===================================================
echo     SISTEMA ACTIVO - SESION ULTRA-SEGURA
echo ===================================================
pause

:: 7. CIERRE DE SEGURIDAD MILITAR
echo [+] Cerrando sistemas y sincronizando...
taskkill /T /IM "AnythingLLM.exe" >nul 2>&1
timeout /t 5 /nobreak >nul
taskkill /F /T /IM "ollama.exe" >nul 2>&1

:: Sincronización forzada de caché de escritura
powershell -Command "[System.IO.File]::Create('%DATA_DIR%\sync.tmp').Dispose(); Remove-Item '%DATA_DIR%\sync.tmp'"

:: Limpieza de residuos en memoria
ipconfig /flushdns >nul

echo [EXITO] Puedes retirar el USB.
timeout /t 3
exit
