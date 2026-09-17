#: pin this clone to one GitHub account, once

<#
.SYNOPSIS
    Set this clone's commit identity and the GitHub account its pushes use.

.DESCRIPTION
    A clone belongs to ONE account, permanently. This writes three repo-local git
    config keys and is not run again:

        user.name
        user.email
        credential.https://github.com.username   <- which account GCM serves

    It also sets user.useConfigOnly, so git refuses to invent an identity from the
    hostname rather than silently using one.

    NOTHING IS WRITTEN TO THE REPOSITORY. All of it lands in .git/config, which
    git never tracks -- which is what keeps a name or address out of a public fork.
    It is also why this is per clone: a second machine, or a re-clone, runs it again.

    You do not switch this afterwards, and you do not need to. Changing which
    account 'gh' acts as is 'gh auth switch', which after 'auth repair' has no
    effect on git at all.

.PARAMETER Account
    The GitHub account this clone pushes as, e.g. the owner of your fork.

.PARAMETER Name
    Commit author name. Defaults to what this clone already has, then to the
    GitHub profile name, then it asks.

.PARAMETER Email
    Commit author address. Defaults to what this clone already has, then it asks,
    suggesting GitHub's noreply address so a private address need not be published.

.EXAMPLE
    .\contrib\maku.ps1 identity init makubexD
.EXAMPLE
    .\contrib\maku.ps1 identity init someone -Name 'Some One' -Email some@one.example
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Account,
    [string]$Name,
    [string]$Email
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1')  -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Identity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Auth.psm1')     -Force
Use-NativeExitCodes

$current = Get-RepoIdentity

# Asks GitHub rather than making the user retype what it already knows. Failure
# here is unremarkable -- gh may be absent, or the account may be one it has no
# token for -- so it falls through to asking.
function Get-GitHubProfile([string]$login, [string]$field) {
    if (-not (Test-GhPresent)) { return $null }
    $value = gh api "users/$login" --jq ".$field" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value -or $value -eq 'null') { return $null }
    return $value.Trim()
}

function Read-Value([string]$label, [string]$suggestion) {
    $shown = if ($suggestion) { " [$suggestion]" } else { '' }
    try {
        $answer = Read-Host "  $($label.PadRight(14))$shown"
    } catch {
        throw (New-Refusal `
            "This needs an interactive console to ask for the $label." `
            "pass it directly: .\contrib\maku.ps1 identity init $Account -Name '...' -Email '...'")
    }
    if ([string]::IsNullOrWhiteSpace($answer)) { return $suggestion }
    return $answer.Trim()
}

if (-not $Name) {
    $Name = $current.Name
    if (-not $Name) { $Name = Get-GitHubProfile $Account 'name' }
    if (-not $Name) { $Name = $Account }
    $Name = Read-Value 'Commit name' $Name
}

if (-not $Email) {
    $Email = $current.Email
    if (-not $Email) {
        # GitHub's own noreply address: publishable by design, and it still links
        # the commit to the account.
        $id = Get-GitHubProfile $Account 'id'
        if ($id) { $Email = "$id+$Account@users.noreply.github.com" }
    }
    $Email = Read-Value 'Commit email' $Email
}

if (-not $Name -or -not $Email) {
    throw (New-Refusal "A commit name and email are both required." `
                       ".\contrib\maku.ps1 identity init $Account -Name '...' -Email '...'")
}

Set-RepoIdentity $Name $Email $Account

Write-Pass 'identity' "$Name <$Email>  push-as:$Account"
Write-Host ""

$owner = Get-RemoteOwner (Get-OriginUrl)
if ($owner -and $owner -ine $Account) {
    Write-Warn 'origin' "origin belongs to '$owner', not '$Account' -- a push would be refused."
    Write-Host ""
}

$auth = Get-AuthState
if ($auth.GhIsHelper) {
    Write-Warn 'helper' 'gh is still the git credential helper, so this pin is not yet honoured.'
    Write-Host "         fix: .\contrib\maku.ps1 auth repair"
} elseif ($auth.GcmPresent -and ($Account -notin $auth.GcmAccounts)) {
    # Gated on GcmPresent, not on the list being non-empty: an empty list is the
    # case where this notice matters most -- GCM holds nothing for anyone yet.
    Write-Host "GCM has no credential for '$Account' yet -- the first push signs in once,"
    Write-Host "then never again. Verify it afterwards: .\contrib\maku.ps1 auth show"
}

Write-Host ""
Write-Host "Next: .\contrib\maku.ps1 guard enable    (check every push before it leaves)"
