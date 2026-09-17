#: which images this project pins, and whether every file agrees

<#
.SYNOPSIS
    Print the pinned images and the state of the files that mirror the browser digest.
#>
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force

Write-Host ""
Write-Host ("  {0,-16} {1}" -f 'app (local)',     (Get-ImagePin 'AppLocal'))
Write-Host ("  {0,-16} {1}" -f 'app (published)', (Get-ImagePin 'AppPublished'))
Write-Host ("  {0,-16} {1}" -f 'browser',         (Get-ImagePin 'Browser'))
Write-Host ""

$state  = Get-BrowserPinState
$agreed = @($state.Files | Where-Object { $_.Agrees })

foreach ($f in $state.Files) {
    if ($f.Agrees) { Write-Host ("  ok        {0}" -f $f.File) }
    else           { Write-Host ("  {0,-9} {1}  ({2})" -f $f.Note, $f.File, $f.Found) -ForegroundColor Red }
}

Write-Host ""
if ($agreed.Count -eq $state.Files.Count) {
    Write-Host "  browser digest: $($state.Files.Count) mirror(s) + images.psd1, all in agreement"
} else {
    Write-Host "  browser digest: MIRRORS DISAGREE" -ForegroundColor Red
    Write-Host "  fix: .\contrib\maku.ps1 images pin browser $((Get-ImagePin 'Browser') -replace '.*@','')"
}
Write-Host ""
