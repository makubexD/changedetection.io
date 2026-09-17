#: set the browser digest everywhere it appears, from one value

<#
.SYNOPSIS
    Rewrite the browser image digest in images.psd1 and every file mirroring it.

.PARAMETER Target
    Which image to pin. Only 'browser' is pinned by digest; the app images are
    tags and are edited in images.psd1 directly.

.PARAMETER Digest
    The new digest, as sha256:<64 hex chars>.

.EXAMPLE
    .\contrib\maku.ps1 images pin browser sha256:a61e64a6...

.NOTES
    Find a digest deliberately, rather than tracking :latest:
        podman pull docker.io/dgtlmoon/sockpuppetbrowser:latest
        podman image inspect docker.io/dgtlmoon/sockpuppetbrowser:latest --format '{{.Digest}}'
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('browser')]
    [string]$Target,

    [Parameter(Mandatory, Position = 1)]
    [string]$Digest
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force

$touched = Set-ImagePin $Digest

if ($touched.Count -eq 0) {
    Write-Host "Already pinned to $Digest everywhere -- nothing to change."
    exit 0
}

Write-Host "Pinned browser to $Digest in:"
$touched | ForEach-Object { Write-Host "    $_" }
Write-Host ""

& (Join-Path $PSScriptRoot 'verify.ps1')
exit $LASTEXITCODE
