#: fail if any file's browser digest has drifted from images.psd1

<#
.SYNOPSIS
    Exit non-zero when the browser digest is not identical everywhere.

.DESCRIPTION
    The digest lives in contrib/images.psd1 and is copied into the compose file,
    the kube manifest and the quadlet unit, none of which can read PowerShell.
    This is what turns that copying from a thing that silently drifts into a
    thing that fails a check.
#>
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force

$state = Get-BrowserPinState
$bad   = @($state.Files | Where-Object { -not $_.Agrees })

if ($bad.Count -eq 0) {
    Write-Pass 'images' "$($state.Files.Count) mirror(s) agree with images.psd1"
    exit 0
}

foreach ($f in $bad) {
    Write-Fail $f.Note "$($f.File)  found: $($f.Found)"
}
Write-Host ""
Write-Host "expected: $($state.Expected)"
Write-Host "  fix: .\contrib\maku.ps1 images pin browser <digest>"
exit 1
