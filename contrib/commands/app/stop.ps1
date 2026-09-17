#: stop and remove the app containers, keeping all data

<#
.SYNOPSIS
    Remove the app container, the browser container and the pod.

.DESCRIPTION
    The named volume changedetection-data is NOT touched, so every watch and its
    history survives. Starting again reattaches it.

    To destroy the data as well -- which cannot be undone -- remove the volume
    explicitly:  podman volume rm changedetection-data

.EXAMPLE
    .\contrib\maku.ps1 app stop
#>
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force

Test-PodmanReady
$n = Get-PodmanNames
Remove-Stack @($n.App, $n.Browser) $n.Pod
Write-Pass 'stop' "containers removed; volume $($n.Volume) kept"
