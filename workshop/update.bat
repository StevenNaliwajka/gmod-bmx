@echo off
rem Upload a NEW VERSION of BMX Bike to the Workshop item publish.bat created.
setlocal
set "HERE=%~dp0"
set "GMP="
for /f "usebackq delims=" %%G in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%find-gmpublish.ps1"`) do set "GMP=%%G"
if not defined GMP (
    echo Could not find gmpublish.exe on its own.
    echo It is in your Garry's Mod folder, under bin\gmpublish.exe
    echo ^(Steam: right-click Garry's Mod, Manage, Browse local files^).
    set /p GMP=Paste its full path here and press Enter: 
)
set "GMP=%GMP:"=%"
if not exist "%GMP%" ( echo Not found: %GMP% & pause & exit /b 1 )
echo Using %GMP%

echo.
set /p WSID=Workshop ID of BMX Bike (the number publish.bat printed): 
set /p NOTE=What changed in this version (one line): 
echo.
echo   Steam must be running and signed in as ConvexBurrito5.
pause
"%GMP%" update -addon "%HERE%bmx.gma" -id "%WSID%" -changes "%NOTE%"
echo.
pause
