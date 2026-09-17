#: would a push be allowed right now? (what the pre-push hook runs)

<#
.SYNOPSIS
    Refuse a push that would publish the wrong identity.

.DESCRIPTION
    Run by the pre-push hook, and runnable by hand. Reads the pushed ref ranges
    on stdin, exactly as git supplies them to a pre-push hook:

        <local ref> <local sha> <remote ref> <remote sha>

    THE CHECK THAT MATTERS IS THE COMMIT RANGE. Config being right at this
    instant says nothing about the authorship of what is being published: a
    commit made before this clone was set up, or on a branch where the identity
    was never applied, sails through a config check and is then public and
    permanent. A wrong-account PUSH fails or can be corrected; a wrong-author
    COMMIT is in the object graph forever.

.PARAMETER Remote
    The remote name or URL git passed as the hook's first argument.

.PARAMETER Url
    The actual push URL git passed as the hook's second argument. This is the
    destination being written to, which is not necessarily 'origin'.

.EXAMPLE
    .\contrib\maku.ps1 guard check
#>
param(
    [string]$Remote,
    [string]$Url
)
$ErrorActionPreference = 'Stop'

# Runs from two places: contrib/commands/guard/ in a checkout, and .git/fork-guard/
# once installed. The modules sit beside it in the second case.
$libDir = if (Test-Path (Join-Path $PSScriptRoot 'Identity.psm1')) { $PSScriptRoot }
          else { Join-Path $PSScriptRoot '..\..\lib' }
Import-Module (Join-Path $libDir 'Repo.psm1')     -Force
Import-Module (Join-Path $libDir 'Console.psm1')  -Force
Import-Module (Join-Path $libDir 'Identity.psm1') -Force
Import-Module (Join-Path $libDir 'Auth.psm1')     -Force
Use-NativeExitCodes

$Zero     = '0000000000000000000000000000000000000000'
$problems = [System.Collections.ArrayList]::new()
function Add-Problem([string]$Text) { [void]$problems.Add($Text) }

$id = Get-RepoIdentity

# --- 1. This clone has an identity at all ------------------------------------
if (-not $id.Email -or -not $id.Name) {
    Add-Problem (New-Refusal `
        "This clone sets no local user.name/user.email, so commits take the machine's global identity ($($id.InheritedEmail))." `
        ".\contrib\maku.ps1 identity init <account>")
}
if (-not $id.Account) {
    Add-Problem (New-Refusal `
        "No GitHub account is pinned for this clone, so pushes fall back to the machine default ($($id.InheritedAccount))." `
        ".\contrib\maku.ps1 identity init <account>")
}

# --- 2. Nothing in the environment is overriding that ------------------------
# GH_TOKEN/GITHUB_TOKEN make gh's credential helper skip its own username check
# entirely and hand out that token whatever account was asked for.
foreach ($name in 'GH_TOKEN', 'GITHUB_TOKEN') {
    if ([Environment]::GetEnvironmentVariable($name)) {
        Add-Problem (New-Refusal `
            "$name is set, which overrides the account this clone is pinned to." `
            "Remove-Item Env:$name")
    }
}
foreach ($name in 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_EMAIL') {
    if ([Environment]::GetEnvironmentVariable($name)) {
        Add-Problem (New-Refusal `
            "$name is set, which overrides user.email for every commit made in this shell." `
            "Remove-Item Env:$name")
    }
}

# --- 3. The destination belongs to this clone's account ----------------------
# Uses the URL git is ACTUALLY pushing to, not remote.origin.url -- a push to a
# second remote, or to a literal URL with no remote at all, reaches this hook too
# and the old check validated 'origin' regardless.
if ($Url -and $id.Account) {
    $owner = Get-RemoteOwner $Url
    if (-not $owner) {
        Add-Problem "Could not read an owner from the push URL '$Url'."
    } elseif ($owner -ine $id.Account) {
        Add-Problem (New-Refusal `
            "This push goes to '$owner', but this clone is pinned to the account '$($id.Account)'." `
            "push to your own fork, or re-pin with: .\contrib\maku.ps1 identity init $owner")
    }
}

# --- 4. Remotes that are not yours cannot be pushed to -----------------------
# A remote added without a push URL pushes to its FETCH url, so an unset value is
# not safe -- it has to be explicitly disabled.
# NOT $remote: PowerShell variable names are case-insensitive, so $remote IS the
# [string]$Remote parameter above, and every object assigned to it would be
# silently coerced to its string form.
foreach ($foreign in (Get-ForeignRemotes $id.Account)) {
    if ($foreign.PushUrl -and $foreign.PushUrl.Trim() -ceq 'DISABLED') { continue }
    $was = if ($foreign.PushUrl) { "'$($foreign.PushUrl.Trim())'" } else { 'unset, so it falls back to the fetch URL' }
    Add-Problem (New-Refusal `
        "Remote '$($foreign.Name)' points at a repository owned by $($foreign.Owner), and its push URL is $was." `
        "git remote set-url --push $($foreign.Name) DISABLED")
}

# --- 5. THE COMMITS BEING PUSHED --------------------------------------------
$stdin = [Console]::In.ReadToEnd()
$lines = @($stdin -split "`r?`n" | Where-Object { $_.Trim() })

foreach ($line in $lines) {
    $parts = @($line -split '\s+')
    if ($parts.Count -lt 4) { continue }
    $localSha  = $parts[1]
    $remoteRef = $parts[2]
    $remoteSha = $parts[3]

    if ($localSha -eq $Zero) { continue }   # deleting a ref publishes nothing

    # master is the pristine mirror of upstream: its pushes are fast-forwards of
    # commits written by upstream contributors, and auditing their addresses
    # would refuse every sync. This is the ONLY fail-open, and it is now scoped
    # to the ref actually being pushed rather than to whatever is checked out.
    if ($remoteRef -eq 'refs/heads/master') { continue }

    # [string[]] is load-bearing: an if-as-expression unrolls a one-element
    # array back to a STRING, and splatting a string passes it one CHARACTER at
    # a time -- git then fails, $LASTEXITCODE is non-zero, and the range check
    # would silently skip the very commits it exists to inspect.
    [string[]]$range = @()
    if ($remoteSha -eq $Zero) { $range = @($localSha, '--not', '--remotes=origin') }
    else                      { $range = @("$remoteSha..$localSha") }

    $commits = @(& git log --format='%H %ae %ce' @range 2>$null | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { continue }

    $bad = @($commits | Where-Object {
        $f = @($_ -split '\s+')
        ($f[1] -ine $id.Email) -or ($f[2] -ine $id.Email)
    })

    if ($bad.Count -gt 0) {
        $shown = ($bad | Select-Object -First 5 | ForEach-Object {
            $f = @($_ -split '\s+')
            "      $($f[0].Substring(0,9))  author=$($f[1])  committer=$($f[2])"
        }) -join [Environment]::NewLine
        $more = if ($bad.Count -gt 5) { [Environment]::NewLine + "      ... and $($bad.Count - 5) more" } else { '' }
        Add-Problem (
            "$($bad.Count) commit(s) bound for $remoteRef are not authored by $($id.Email):" +
            [Environment]::NewLine + $shown + $more + [Environment]::NewLine +
            "  fix: rewrite them with an interactive rebase, resetting the author")
    }
}

# --- Advisory: gh's account affects gh commands, not this push ---------------
$auth = Get-AuthState

# DELIBERATELY A WARNING HERE, AND A FAILURE IN 'identity show'. The two are not
# in disagreement, they are answering different questions. This hook exists to
# stop a bad COMMIT being published, and that is irreversible. A wrong credential
# helper cannot produce one: it makes the push fail to authenticate, loudly and
# recoverably. Refusing here would block pushes that are perfectly safe, over a
# condition the push itself already reports. 'identity show' asks "is this clone
# set up correctly", and for that question it plainly is not -- so it fails.
if ($auth.GhIsHelper) {
    Write-Warn 'helper' "gh is the git credential helper, so pushes depend on its ACTIVE account."
    Write-Host "         Not blocking this push: a wrong helper makes a push FAIL, it cannot"
    Write-Host "         publish a wrong author. 'identity show' does treat it as a failure."
    Write-Host "         fix: .\contrib\maku.ps1 auth repair"
}
# Reported even when gh cannot be reached. Guarding this on GhActive being
# truthy meant an offline machine or an expired token silently dropped the
# warning -- clean-looking output for an unchecked condition.
if ($auth.GhPresent -and -not $auth.GhKnown) {
    Write-Warn 'gh' "gh could not be queried, so which account gh pr create would act as is UNVERIFIED."
} elseif ($auth.GhActive -and $id.Account -and $auth.GhActive -ine $id.Account) {
    Write-Warn 'gh' "gh is active as $($auth.GhActive), so gh pr create here would act as that account."
    Write-Host "         fix: gh auth switch -u $($id.Account)"
}

if ($problems.Count -eq 0) {
    Write-Pass 'guard' "$($id.Name) <$($id.Email)>  push-as:$($id.Account)"
    exit 0
}

Write-Host ""
foreach ($p in $problems) { Write-Fail 'guard' $p; Write-Host "" }
exit 1
