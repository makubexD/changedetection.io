#: stop gh being the git credential helper, so nothing prompts again

<#
.SYNOPSIS
    Undo 'gh auth setup-git', handing github.com back to Git Credential Manager.

.DESCRIPTION
    Removes exactly the entries 'gh auth setup-git' added -- an empty
    credential.https://github.com.helper (which resets the helper list, discarding
    GCM) and the gh helper that follows it -- in whichever scope holds them, and
    nothing else.

    AFTER THIS, nothing needs switching for git. Each repository authenticates as
    the account named by its own credential.<url>.username, from GCM's per-account
    store. 'gh auth switch' still changes who 'gh pr create' and 'gh api' act as,
    and no longer touches git at all.

    Work repositories keep working immediately if GCM already holds their account.
    Any account GCM does not yet hold signs in once, interactively, on its first
    push -- and because the browser may be signed in as someone else, verify which
    account was stored before trusting it:

        .\contrib\maku.ps1 auth show

    REVERSIBLE in one command: gh auth setup-git

.EXAMPLE
    .\contrib\maku.ps1 auth repair
.EXAMPLE
    .\contrib\maku.ps1 auth repair -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Auth.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Use-NativeExitCodes

$before = Get-AuthState

if (-not $before.GhIsHelper) {
    Write-Pass 'auth' "gh is not the credential helper -- nothing to repair."
    Write-Host "  github.com helper: $($before.Helper)"
    exit 0
}

if (-not $before.GcmPresent) {
    throw (New-Refusal `
        "Git Credential Manager is not installed, so removing the gh helper would leave nothing to authenticate with." `
        "install Git for Windows with GCM, or keep the current setup and accept the prompts")
}

Write-Host "Will remove these entries (installed by 'gh auth setup-git'):"
Write-Host ""

# The VALUES are printed, not just the keys. Each host legitimately has two
# entries with the same key, and without their values that reads as the tool
# double-counting -- when in fact the pair IS the mechanism being undone: the
# empty value resets the helper list (discarding GCM), and gh then takes over as
# the only helper. See ADR-IDENTITY.md.
foreach ($o in $before.GhOrigins) {
    $note = if ($o.Value) { $o.Value } else { '(empty -- resets the helper list, discarding GCM)' }
    Write-Host "    $($o.Key)"
    Write-Host "        = $note"
}
Write-Host ""
Write-Host "  in: $(($before.GhOrigins | Select-Object -ExpandProperty File -Unique) -join ', ')"
Write-Host ""
Write-Host "  Afterwards github.com is served by GCM, which holds one credential per"
Write-Host "  account and picks per repository. Nothing else in global config changes."
# Stated BEFORE the prompt, not after it: this is the moment the decision is
# made, so the way back belongs on screen here.
Write-Host "  Undo at any time:  gh auth setup-git"
Write-Host ""

if (-not $PSCmdlet.ShouldProcess('git credential configuration for github.com',
                                 'remove the gh credential helper, restoring GCM')) {
    exit 0
}

$results = @(Repair-GitHubCredentialHelper)
$removed = @($results | Where-Object { $_.Removed })
$failed  = @($results | Where-Object { -not $_.Removed })

foreach ($r in $removed) { Write-Host "    removed  $($r.Scope): $($r.Key)" }

# Named, never swallowed: an entry this could not remove is the difference
# between a repair and a partial one, and it decides whether anything else here
# can be believed.
foreach ($f in $failed) {
    Write-Host ""
    Write-Warn 'auth' "could NOT remove  $($f.Scope): $($f.Key)"
    if ($f.Error) { Write-Host "         git said: $($f.Error)" }
    if ($f.Scope -eq 'system') {
        Write-Host "         The system config is machine-wide. Reading it needs nothing;"
        Write-Host "         changing it needs an ELEVATED shell -- re-run this from one."
    }
}

$after = Get-AuthState
Write-Host ""
if ($after.GhIsHelper) {
    Write-Fail 'auth' "gh is still the helper: $($after.Helper)"
    if ($failed | Where-Object { $_.Scope -eq 'system' }) {
        Write-Host "  cause: the entry in the SYSTEM config could not be removed (see above)."
        Write-Host "  fix:   re-run this from an elevated shell"
    }
    exit 1
}
Write-Pass 'auth' "github.com now served by: $($after.Helper)"

Write-Host ""
Write-Host "GCM holds: $(if ($after.GcmAccounts) { $after.GcmAccounts -join ', ' } else { 'nothing yet' })"
Write-Host "Any account not listed signs in once on its first push, then never again."
Write-Host "Verify what was stored before trusting it:  .\contrib\maku.ps1 auth show"
Write-Host ""
Write-Host "Undo:  gh auth setup-git"
