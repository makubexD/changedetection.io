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
# The name is read first and reused, rather than taken back out of Build-Image.
# A function that returns its own input parameter through the pipeline shares
# that pipeline with the command it runs -- which is how podman's image ID ended
# up in this line.
$image = Get-ImagePin 'AppLocal'
Build-Image $image -NoCache:$NoCache
Add-Action 'built' "$image from $((& git rev-parse --short HEAD).Trim())"
Write-Pass 'build' $image
