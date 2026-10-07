@echo off
rem Publish the BMX addon to the Steam Workshop as a NEW item.
rem Run this ONCE. Every later release uses update.bat instead: running this
rem again makes a second Workshop item rather than updating the first.
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

rem BMX IS ALREADY PUBLISHED. Creating again makes a second item that
rem nobody is subscribed to, so it takes typing NEW to do it on purpose.
if not exist "%HERE%workshop-id.txt" goto create
set /p WSID=<"%HERE%workshop-id.txt"
echo   BMX is already on the Workshop as item %WSID%.
echo   To release a new version, close this and run update.bat instead.
set /p CONFIRM=Type NEW to create a SECOND, separate item anyway: 
if /i not "%CONFIRM%"=="NEW" exit /b 1
:create

echo.
echo   Uploading BMX to the Steam Workshop as a NEW item.
echo.
echo   Before you go on:
echo     1. Steam is running and signed in as ConvexBurrito5.
echo     2. That account owns Garry's Mod.
echo.
pause
"%GMP%" create -addon "%HERE%bmx.gma" -icon "%HERE%icon.jpg"
echo.
echo   Write down the Workshop ID printed above ("UID" / "id").
echo   update.bat asks for it every time you release a new version.
echo.
echo   Then open the item on the Workshop (Steam, Garry's Mod, Workshop,
echo   Your Files): accept the Workshop agreement if Steam asks, and set
echo   Visibility to Public when you are ready for people to see it.
echo.
pause
