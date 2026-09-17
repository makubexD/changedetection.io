#: stop checking on push

<#
.SYNOPSIS
    Remove the pre-push guard from this clone.

.DESCRIPTION
    Removes .git/hooks/pre-push and .git/fork-guard/. Refuses to touch a pre-push
    hook this tool did not write.

.EXAMPLE
    .\contrib\maku.ps1 guard disable
#>
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Guard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force

if (Uninstall-Guard) { Write-Pass 'guard' 'disabled' }
else                 { Write-Host 'Guard was already off.' }
