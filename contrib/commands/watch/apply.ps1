#: create a watch from a plan file, and prove it checked

<#
.SYNOPSIS
    Turn a generated watch.json into a real watch, and show what it actually saw.

.DESCRIPTION
    Two ways to apply a plan, chosen by whether -AsZip is given:

      - API (default): POSTs to /api/v1/watch, forces an immediate recheck, then
        polls the watch until that check lands and prints what it captured. This
        is the only path that PROVES the selector matched something real, rather
        than merely being accepted -- CSS selectors are never validated at
        import time (forms.py has no CSS validator), so "created successfully"
        and "works" are different claims.

      - ZIP (-AsZip): writes <uuid>/watch.json into a .zip for Settings ->
        Backup -> Restore, splitting out processor_config_<name> (if the plan
        carries one) into its own file the way the app itself stores it.
        No API key needed, but there is no verify step -- you find out it works
        when the scheduler runs it.

    Test-WatchPlan (contrib/lib/WatchPlan.psm1) runs first either way, so a plan
    with a quiet-failure field (see contrib/podman/WATCHING.md) is refused with
    a sentence instead of becoming a watch that never fires.

.PARAMETER File
    Path to the plan's watch.json.

.PARAMETER ApiKey
    The API key from Settings -> API. Falls back to $env:MAKU_API_KEY. Required
    unless -AsZip is given.

.PARAMETER Port
    Port the app is published on. Defaults to 5000, matching 'app start'.

.PARAMETER AsZip
    Write a restore ZIP to this path instead of calling the API.

.PARAMETER SkipVerify
    POST the watch and stop -- do not force a recheck or wait for it. Useful
    when the URL is expected to take a long time on its first check.

.PARAMETER TimeoutSec
    How long to wait for the forced recheck to land. Default 60.

.EXAMPLE
    .\contrib\maku.ps1 watch apply -File plan.json
.EXAMPLE
    .\contrib\maku.ps1 watch apply -File plan.json -AsZip out.zip
#>
param(
    [Parameter(Mandatory = $true)][string]$File,
    [string]$ApiKey = $env:MAKU_API_KEY,
    [int]$Port = 5000,
    [string]$AsZip,
    [switch]$SkipVerify,
    [int]$TimeoutSec = 60
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\WatchPlan.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Use-NativeExitCodes

if (-not (Test-Path $File)) {
    throw (New-Refusal "No plan file at '$File'." "check the path, or generate one with the watch-from-url skill first")
}
$plan = Get-Content $File -Raw | ConvertFrom-Json

Write-Stage 'checking the plan'
Test-WatchPlan $plan
Write-Pass 'plan' "no quiet-failure fields found ($File)"

if ($AsZip) {
    Write-Stage 'exporting'
    $uuid = Export-WatchPlanZip $AsZip $plan
    Add-Action 'exported' "$AsZip (uuid $uuid)"
    Write-Pass 'zip' $AsZip
    Write-Host ''
    Write-Host "Upload it at Settings -> Backup -> Restore. There is no verify step for this path --"
    Write-Host "the scheduler runs the check on its own interval, or trigger it from the watch's own page."
    exit 0
}

if (-not $ApiKey) {
    throw (New-Refusal "No API key given, and `$env:MAKU_API_KEY is not set." `
                       "pass -ApiKey <key> (Settings -> API), or use -AsZip <path> instead")
}

$baseUrl = "http://localhost:$Port"
Write-Stage 'creating the watch'
$uuid = Invoke-WatchPlanPost $baseUrl $ApiKey $plan
Add-Action 'created' "watch $uuid ($($plan.url))"
Write-Pass 'watch' $uuid

if ($SkipVerify) {
    Write-Host ''
    Write-Host "Created without verifying. Check it yourself: $baseUrl/edit/$uuid"
    exit 0
}

Write-Stage 'checking it for real'
Invoke-WatchRecheckAndReport $baseUrl $ApiKey $uuid $TimeoutSec
