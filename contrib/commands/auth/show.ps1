#: what actually supplies a GitHub credential on this machine

<#
.SYNOPSIS
    Report which credential helper serves github.com, and which accounts are stored where.

.DESCRIPTION
    This is the answer to "why am I being asked for a password". A credential
    failure otherwise looks identical to a bad token:

        remote: Invalid username or token. Password authentication is not supported
        fatal: Authentication failed for 'https://github.com/...'

    That message appears when the GitHub CLI is the credential helper and its
    active account is not the one the repository asked for. gh serves only its
    active account and returns nothing for any other, so the fix is not a new
    token -- it is to stop gh being the helper.

.EXAMPLE
    .\contrib\maku.ps1 auth show
#>
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Auth.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Use-NativeExitCodes

$s = Get-AuthState

Write-Host ""
Write-Host ("  {0,-18} {1}" -f 'github.com helper', $(if ($s.Helper) { $s.Helper } else { 'none configured' }))
# "not installed" and "installed but holding nothing" demand opposite responses,
# so they are never printed as the same thing.
$gcmSummary = if ($s.GcmAccounts) { $s.GcmAccounts -join ', ' }
              elseif ($s.GcmPresent) { 'none stored yet' }
              else { 'not installed' }
Write-Host ("  {0,-18} {1}" -f 'GCM accounts', $gcmSummary)
$ghSummary = if ($s.GhAccounts) { $s.GhAccounts -join ', ' }
             elseif (-not $s.GhPresent) { 'not installed' }
             elseif (-not $s.GhKnown) { 'unknown -- gh could not be queried' }
             else { 'none' }
Write-Host ("  {0,-18} {1}" -f 'gh accounts', $ghSummary)
Write-Host ("  {0,-18} {1}" -f 'gh active', (Get-GhActiveLabel $s))
Write-Host ""

if ($s.GhIsHelper) {
    Write-Host "  DIAGNOSIS  gh is the credential helper for github.com." -ForegroundColor Red
    Write-Host "             It serves ONLY its active account and returns nothing for"
    Write-Host "             any other, so every repository pinned to a different"
    Write-Host "             account is prompted for a password -- and 'gh auth switch'"
    Write-Host "             moves the problem rather than fixing it."
    # On its own line, and only when known: interpolating it inline printed an
    # empty '()' whenever gh could not be queried, which reads as a bug and says
    # less than nothing.
    if ($s.GhActive) {
        Write-Host "             Active right now: $($s.GhActive)"
    }
    Write-Host ""
    Write-Host "             Installed by 'gh auth setup-git', in:"
    $s.GhOrigins | Select-Object -ExpandProperty File -Unique |
        ForEach-Object { Write-Host "               $_" }
    Write-Host ""
    Write-Host "  fix: .\contrib\maku.ps1 auth repair"
    Write-Host ""
    exit 1
}

if (-not $s.HelperIsGcm) {
    Write-Warn 'helper' "github.com is served by '$($s.Helper)', which this project has no opinion about."
    Write-Host "         The per-repository account pin (credential.<url>.username) only works"
    Write-Host "         if that helper honours it. See contrib/fork/ADR-IDENTITY.md."
    Write-Host ""
    exit 0
}

Write-Host "  Git credentials come from GCM, which stores one per account and picks"
Write-Host "  per repository from credential.<url>.username. No switching is needed"
Write-Host "  for git, and 'gh auth switch' affects the CLI only."
Write-Host ""
if (-not $s.GcmAccounts) {
    Write-Warn 'GCM' 'no GitHub accounts stored yet -- the first push will sign in once.'
    Write-Host ""
}
exit 0
