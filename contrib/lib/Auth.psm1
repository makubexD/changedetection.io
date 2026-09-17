# Which mechanism actually supplies a GitHub credential on this machine.
#
# THE DECISION THIS ENCODES (contrib/fork/ADR-IDENTITY.md has the full record):
# git credentials come from Git Credential Manager, and the GitHub CLI is used
# for the CLI and the API only.
#
# WHY. `gh auth git-credential` resolves the token by HOST and serves only the
# ACTIVE account -- asked for any other account it returns nothing and exits 1,
# even when that account's token is sitting in the same keyring. So while gh is
# the credential helper, every `gh auth switch` guarantees a password prompt for
# every repository pinned to a different account. GCM instead stores one
# credential per account, keyed git:https://<user>@github.com, and picks per
# repository from credential.<url>.username -- which is exactly "authenticate
# once, then it works from anywhere".
#
# `gh auth setup-git` is what installs gh as the helper. It writes an EMPTY
# helper entry (which gitcredentials(7) defines as "reset the list", discarding
# GCM) followed by itself. Undoing it is removing those two entries and nothing
# else.

$script:GhHosts = @('https://github.com', 'https://gist.github.com')

# What git would really run for a github.com URL. --get-urlmatch reports the
# last value of a multi-valued key, which is the one that ends up in force.
function Get-GitHubCredentialHelper {
    $helper = & git config --get-urlmatch credential.helper 'https://github.com/' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $helper) { return $null }
    return $helper.Trim()
}

function Test-GhIsHelper {
    $helper = Get-GitHubCredentialHelper
    return [bool]($helper -and $helper -match 'auth\s+git-credential')
}

# Where the gh helper entries live, so 'auth repair' edits the scope that
# actually holds them rather than assuming --global.
function Get-GhHelperOrigins {
    $rows = & git config --show-origin --get-regexp 'credential\..*github\.com\.helper' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $rows) { return @() }
    $out = foreach ($row in @($rows)) {
        if ($row -match '^file:(\S+)\s+(\S+)\s*(.*)$') {
            [pscustomobject]@{ File = $Matches[1]; Key = $Matches[2]; Value = $Matches[3] }
        }
    }
    return @($out)
}

# Directories that hold GCM but are not necessarily on PATH. Git for Windows
# bundles it as a sibling of git's own exec-path:
#   <root>\mingw64\libexec\git-core  ->  <root>\mingw64\bin
function Get-GcmSearchDirectory {
    $dirs = [System.Collections.Generic.List[string]]::new()
    $exec = & git --exec-path 2>$null
    if ($LASTEXITCODE -eq 0 -and $exec) {
        $mingw = [System.IO.Path]::GetDirectoryName(
                 [System.IO.Path]::GetDirectoryName($exec.Trim()))
        if ($mingw) { $dirs.Add((Join-Path $mingw 'bin')) }
    }
    # Where the standalone GCM installer puts it.
    if ($env:LOCALAPPDATA) {
        $dirs.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git Credential Manager'))
    }
    return $dirs
}

# The GCM executable, or $null. Resolved by LOCATION, not by bare name.
#
# THIS IS LOAD-BEARING. On Windows GCM ships inside Git's own directory, which
# Git Bash puts on PATH and PowerShell does not. A bare
# `Get-Command git-credential-manager` therefore reports "not installed" on a
# machine where GCM is installed and already holding credentials -- and since
# `auth repair` refuses to run without GCM, that false negative made the whole
# migration impossible from the only shell this CLI runs in.
function Get-GcmPath {
    $names = @('git-credential-manager', 'git-credential-manager-core')
    foreach ($name in $names) {
        $onPath = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
                  Select-Object -First 1
        if ($onPath) { return $onPath.Source }
    }
    foreach ($dir in (Get-GcmSearchDirectory)) {
        foreach ($name in $names) {
            $candidate = Join-Path $dir "$name.exe"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    return $null
}

function Test-GcmPresent {
    return [bool](Get-GcmPath)
}

# The GitHub accounts GCM holds a credential for. These are what make prompting
# unnecessary: one entry per account, selected per repository.
# GcmPath is a parameter so one reading can resolve it once and hand it down:
# resolving costs a `git --exec-path` subprocess, and Get-AuthState needs the
# same answer three times over.
function Get-GcmAccounts([string]$GcmPath = (Get-GcmPath)) {
    $gcm = $GcmPath
    if (-not $gcm) { return @() }
    $out = & $gcm github list 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return @() }
    return @($out | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-GhPresent {
    return [bool](Get-Command gh -ErrorAction SilentlyContinue)
}

# Every account gh has a token for, and which one is active. Reported for the
# CLI's sake only -- after the migration none of it affects git.
#
# NOT `gh api user`, which this used to call. That spent a GitHub API round trip
# to learn one login, and -- the reason it had to go -- returned nothing on
# failure, which callers could not tell apart from "no account is active". Both
# warnings that depend on this were guarded on the value being truthy, so an
# offline machine, a rate limit or an expired token made them SILENTLY VANISH
# and the output looked clean rather than uncertain. A check that was skipped
# must never look like one that passed.
#
# `gh auth status --json hosts` reports every account and which one is active in
# a single call, and is documented to exit 0 even when an account has a token
# problem -- so one bad account no longer erases the whole picture.
#
# Returns $null when gh could not be asked at all. That is a THIRD state,
# distinct both from "gh is not installed" and from "gh is active as nobody",
# and callers must keep it distinct.
function Get-GhState {
    if (-not (Test-GhPresent)) { return $null }
    $raw = gh auth status --json hosts 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try   { $hosts = ($raw | Out-String | ConvertFrom-Json).hosts }
    catch { return $null }
    if (-not $hosts) { return $null }

    # @() around each step: a single-account host would otherwise unroll to a
    # bare object and .Count would report the property count, not one.
    $accounts = @($hosts.'github.com' | Where-Object { $_ })
    $active   = @($accounts | Where-Object { $_.active })
    $activeLogin = $null
    if ($active.Count -ge 1) { $activeLogin = $active[0].login }

    return [pscustomobject]@{
        Accounts = @($accounts | ForEach-Object { $_.login } | Where-Object { $_ })
        Active   = $activeLogin
    }
}

# How the active account should be DISPLAYED. Three outcomes, never collapsed
# into one another -- "unknown" is the whole point of G2.
function Get-GhActiveLabel([object]$State) {
    if (-not $State.GhPresent) { return 'not installed' }
    if (-not $State.GhKnown)   { return 'unknown -- gh could not be queried' }
    if (-not $State.GhActive)  { return 'none' }
    return $State.GhActive
}

# One reading of the whole picture, so 'auth show' and every guard assertion
# agree rather than each asking their own slightly different question.
function Get-AuthState {
    $helper = Get-GitHubCredentialHelper
    $gh     = Get-GhState
    $ghAccounts = @()
    $ghActive   = $null
    if ($gh) { $ghAccounts = @($gh.Accounts); $ghActive = $gh.Active }

    # Resolved once and reused: this used to call Get-GcmPath three times over.
    $gcm = Get-GcmPath
    $gcmAccounts = @()
    if ($gcm) { $gcmAccounts = @(Get-GcmAccounts $gcm) }

    return [pscustomobject]@{
        Helper       = $helper
        GhIsHelper   = [bool]($helper -and $helper -match 'auth\s+git-credential')
        HelperIsGcm  = [bool]($helper -and $helper -match '^manager')
        GcmPath      = $gcm
        GcmPresent   = [bool]$gcm
        GcmAccounts  = $gcmAccounts
        GhPresent    = Test-GhPresent
        GhKnown      = [bool]$gh          # $false = could not be determined
        GhAccounts   = $ghAccounts
        GhActive     = $ghActive
        GhOrigins    = Get-GhHelperOrigins
    }
}

# Removes exactly the entries `gh auth setup-git` added, in whichever scope holds
# them, and nothing else. Reversible with `gh auth setup-git`.
# Reports an OUTCOME PER ENTRY rather than a list of successes. The earlier
# version appended only on exit 0 and discarded stderr, so a write it could not
# perform vanished from the report -- and a partial repair read as a smaller
# successful one. The system scope is the realistic case: reading it needs
# nothing, editing it is machine-wide and needs an elevated shell.
function Repair-GitHubCredentialHelper {
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($scope in @('local', 'global', 'system')) {
        foreach ($h in $script:GhHosts) {
            $key = "credential.$h.helper"
            $existing = & git config --$scope --get-all $key 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $existing) { continue }

            $stderr = (& git config --$scope --unset-all $key 2>&1) | Out-String
            $results.Add([pscustomobject]@{
                Scope   = $scope
                Key     = $key
                Removed = ($LASTEXITCODE -eq 0)
                Error   = $stderr.Trim()
            })
        }
    }
    return $results.ToArray()
}

Export-ModuleMember -Function Get-GitHubCredentialHelper, Test-GhIsHelper, Get-GhHelperOrigins,
                              Get-GcmPath, Test-GcmPresent, Get-GcmAccounts,
                              Test-GhPresent, Get-GhState, Get-GhActiveLabel,
                              Get-AuthState, Repair-GitHubCredentialHelper
