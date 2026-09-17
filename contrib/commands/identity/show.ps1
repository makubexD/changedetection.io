#: is this clone set up correctly?

<#
.SYNOPSIS
    Report this clone's identity, the credential mechanism behind it, and the guard.

.DESCRIPTION
    Three separate things decide who you are here, and they fail differently:

        user.name / user.email                    who AUTHORED the commit
        credential.https://github.com.username    which account GCM serves
        gh's active account                       who 'gh pr create' acts as

    All three are printed, because the one that is invisible is the one that
    catches people out. This reports; it changes nothing.

.EXAMPLE
    .\contrib\maku.ps1 identity show
#>
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1')  -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Identity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Auth.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Guard.psm1')    -Force
Use-NativeExitCodes

$id    = Get-RepoIdentity
$auth  = Get-AuthState
$state = Get-GuardState
$owner = Get-RemoteOwner (Get-OriginUrl)
$bad   = @()

Write-Host ""
Write-Host ("  {0,-12} {1}" -f 'commits as', $(if ($id.Name) { "$($id.Name) <$($id.Email)>" } else { 'NOT SET LOCALLY' }))
Write-Host ("  {0,-12} {1}" -f 'push as',    $(if ($id.Account) { $id.Account } else { 'NOT SET LOCALLY' }))
Write-Host ("  {0,-12} {1}" -f 'origin',     $(if ($owner) { $owner } else { 'unknown' }))
Write-Host ("  {0,-12} {1}" -f 'helper',     $(if ($auth.Helper) { $auth.Helper } else { 'none' }))
Write-Host ("  {0,-12} {1}" -f 'gh active',  (Get-GhActiveLabel $auth))
Write-Host ("  {0,-12} {1}" -f 'push guard', $state)
Write-Host ""

if (-not $id.Name -or -not $id.Email -or -not $id.Account) {
    $bad += New-Refusal `
        "This clone does not set its own identity, so it inherits the machine's ($($id.InheritedEmail))." `
        ".\contrib\maku.ps1 identity init <account>"
}
if ($owner -and $id.Account -and $owner -ine $id.Account) {
    $bad += "origin belongs to '$owner' but this clone pushes as '$($id.Account)'."
}
if ($auth.GhIsHelper) {
    $bad += New-Refusal `
        "gh is the git credential helper, so only its ACTIVE account can authenticate and every other repository is prompted for a password." `
        ".\contrib\maku.ps1 auth repair"
}
if ($state -eq 'stale') {
    # Two causes, one fix: a hook from the old tooling pointing at files this
    # change removed, or a file missing from .git/fork-guard so check.ps1 cannot
    # even load. Either way the check cannot run, and a hook that cannot run its
    # check is not a check.
    $bad += New-Refusal `
        "The push guard is STALE: either the installed hook predates this tooling, or a file it needs under .git/fork-guard is missing. Either way its check cannot run." `
        ".\contrib\maku.ps1 guard enable"
} elseif ($state -eq 'drifted') {
    # The check still runs; it is an older revision of it. A warning, not a
    # refusal -- see the reasoning on Get-GuardState in lib/Guard.psm1.
    Write-Warn 'guard' "its copies under .git/fork-guard are older than contrib/lib, so pushes are checked by out-of-date logic."
    Write-Host "         fix: .\contrib\maku.ps1 guard enable"
} elseif ($state -eq 'off') {
    Write-Warn 'guard' "off -- pushes are not checked. Enable it: .\contrib\maku.ps1 guard enable"
} elseif ($state -eq 'foreign') {
    Write-Warn 'guard' "a pre-push hook this tool did not write is installed; it was left alone."
}
# The unknown case is reported, never skipped: this warning used to be guarded
# on GhActive being truthy, so a failed lookup made it disappear and the output
# looked clean rather than uncertain.
if ($auth.GhPresent -and -not $auth.GhKnown) {
    Write-Warn 'gh' "could not be queried, so which account 'gh pr create' would act as is UNVERIFIED here."
    Write-Host "         check it yourself: gh auth status"
} elseif ($auth.GhActive -and $id.Account -and $auth.GhActive -ine $id.Account) {
    Write-Warn 'gh' "active as '$($auth.GhActive)', so 'gh pr create' here would act as that account."
    Write-Host "         fix: gh auth switch -u $($id.Account)"
}

# A leftover from the profile store this tooling replaced. Harmless, but it looks
# like configuration and is not, so say so rather than leave it to be trusted.
foreach ($leftover in 'fork-identity.json', 'fork-identity-backup.json') {
    if (Test-Path (Join-Path (Get-GitCommonDir) $leftover)) {
        Write-Warn 'obsolete' ".git/$leftover is left over from the old profile store and is no longer read."
    }
}

if ($bad.Count -gt 0) {
    Write-Host ""
    foreach ($b in $bad) { Write-Fail 'identity' $b; Write-Host "" }
    exit 1
}

Write-Pass 'identity' 'this clone is pinned, and the credential mechanism honours it'
exit 0
