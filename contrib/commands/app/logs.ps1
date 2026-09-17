#: follow the app's logs, or Chrome's

<#
.SYNOPSIS
    Follow container logs.

.PARAMETER Browser
    Follow the sockpuppetbrowser container instead. Chrome crashes show up there
    and nowhere else -- the app only ever sees a failed fetch.

.PARAMETER Tail
    How many existing lines to show before following.

.EXAMPLE
    .\contrib\maku.ps1 app logs
.EXAMPLE
    .\contrib\maku.ps1 app logs -Browser -Tail 80
#>
param(
    [switch]$Browser,
    [int]$Tail = 100
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force

Test-PodmanReady
$n    = Get-PodmanNames
$name = if ($Browser) { $n.Browser } else { $n.App }
& podman logs --tail $Tail -f $name
