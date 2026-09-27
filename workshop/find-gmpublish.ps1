# Prints the full path of Garry's Mod's gmpublish.exe, or nothing.
# Looks where Steam says it is (registry), then in every Steam library folder
# Steam knows about (steamapps\libraryfolders.vdf), then the default install.
$libs = @()
$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
if ($steam) {
    $steam = $steam -replace '/', '\'
    $libs += $steam
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches)) {
            foreach ($g in $m.Matches) { $libs += ($g.Groups[1].Value -replace '\\\\', '\') }
        }
    }
}
$libs += "${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam"
foreach ($l in $libs) {
    $p = Join-Path $l 'steamapps\common\GarrysMod\bin\gmpublish.exe'
    if (Test-Path $p) { Write-Output $p; exit 0 }
}
exit 1
