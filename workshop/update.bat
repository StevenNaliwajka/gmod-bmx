@echo off
rem Upload a NEW VERSION of BMX to the Workshop item publish.bat created.
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
rem THE LIVE ITEM'S ID SHIPS IN THE KIT (workshop-id.txt), so nobody types it:
rem a mistyped ID updates nothing, or somebody else's item.
set "WSID="
if exist "%HERE%workshop-id.txt" set /p WSID=<"%HERE%workshop-id.txt"
if not defined WSID set /p WSID=Workshop ID of BMX (the number publish.bat printed): 
echo Updating Workshop item %WSID%
echo   https://steamcommunity.com/sharedfiles/filedetails/?id=%WSID%
set /p NOTE=What changed in this version (one line): 
echo.
echo   Steam must be running and signed in as ConvexBurrito5.
pause
"%GMP%" update -addon "%HERE%bmx.gma" -id "%WSID%" -changes "%NOTE%"
echo.
pause
