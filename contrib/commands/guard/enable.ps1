#: make every git push run the identity check first

<#
.SYNOPSIS
    Install the pre-push guard into this clone.

.DESCRIPTION
    Copies what the check needs into .git/fork-guard/ and writes .git/hooks/pre-push.
    Both are per-clone and never committed, so this is run once per machine -- and
    again after pulling a change to the tooling, which 'identity show' reports.

    Running the check from .git/ rather than from the working tree is what makes
    it cover feat/* branches, which do not carry contrib/.

.EXAMPLE
    .\contrib\maku.ps1 guard enable
#>
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Guard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force

$contrib = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$hook = Install-Guard $contrib

Write-Pass 'guard' "enabled -- every git push from this clone is checked first"
Write-Host "  hook:   $hook"
Write-Host "  bypass: git push --no-verify"
Write-Host "  off:    .\contrib\maku.ps1 guard disable"
