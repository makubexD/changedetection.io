#: how far this fork is ahead of and behind upstream

<#
.SYNOPSIS
    Read GitHub's "N commits ahead, M commits behind" banner without opening a browser.

.DESCRIPTION
    Only one of those two numbers is actionable:

        behind   upstream has commits this branch has not taken. Should be 0 --
                 that is what 'fork sync' is for, and the drift compounds if it
                 is left, because the eventual conflicts grow with it.
        ahead    this branch has commits upstream does not. Should NOT be 0 --
                 that is the work this fork exists to carry. A fork that carries
                 changes is ahead by definition, and the only way to show 0 is to
                 carry nothing.

.PARAMETER Branch
    Which branch to report on. Defaults to the one checked out.

.EXAMPLE
    .\contrib\maku.ps1 fork status
#>
param([string]$Branch)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Use-NativeExitCodes

if (-not $Branch) { $Branch = Get-CurrentBranch }

& git rev-parse --verify --quiet upstream/master | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw (New-Refusal "This clone has no upstream/master to compare against." `
                       ".\contrib\maku.ps1 fork sync   (it adds the remote and fetches)")
}

$ahead  = (& git rev-list --count "upstream/master..$Branch").Trim()
$behind = (& git rev-list --count "$Branch..upstream/master").Trim()

$behindNote = if ($behind -eq '0') { 'up to date' }
              else { 'real drift -- run: .\contrib\maku.ps1 fork sync' }

Write-Host ""
Write-Host "  $Branch vs dgtlmoon/changedetection.io:master"
Write-Host ""
Write-Host ("    {0,-8} {1,6}   {2}" -f 'ahead',  $ahead,  'the work this fork carries -- expected')
Write-Host ("    {0,-8} {1,6}   {2}" -f 'behind', $behind, $behindNote)
Write-Host ""
