#: build the container image from this repo

<#
.SYNOPSIS
    Build changedetection.io locally with Podman (Buildah).

.PARAMETER NoCache
    Build without the layer cache. Fallback for an older Buildah that mishandles
    the Dockerfile's RUN --mount=type=cache directives.

.EXAMPLE
    .\contrib\maku.ps1 app build
.EXAMPLE
    .\contrib\maku.ps1 app build -NoCache
#>
param([switch]$NoCache)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force

Test-PodmanReady
$image = Build-Image (Get-ImagePin 'AppLocal') -NoCache:$NoCache
Write-Pass 'build' $image
