# Which GitHub account this clone commits and pushes as.
#
#   identity.ps1                          is this clone set up correctly?
#   identity.ps1 capture work             remember how this machine is right now
#   identity.ps1 define fork -From work   a new profile, starting from that one
#   identity.ps1 use fork                 switch to it
#   identity.ps1 protect                  make every git push check first
#   identity.ps1 restore                  put this clone back how it was found
#   identity.ps1 list                     what exists, and what is active
#   identity.ps1 forget <name>            drop a profile you no longer need
#
# NO NAMES OR EMAILS LIVE IN THIS FILE. The fork is public. Profiles go in
# .git\fork-identity.json -- inside .git, which git cannot track, so an identity
# cannot be committed by accident. 'capture' fills that file from the machine
# itself, so nothing is typed twice.
#
# IT ONLY WRITES REPO-LOCAL GIT CONFIG. Your global user.name / user.email are
# never modified and other repositories are unaffected.
#
# THREE THINGS DECIDE WHO YOU ARE HERE, and gh owns only the third:
#   user.name / user.email                     -> who authored the commit
#   credential.https://github.com.username     -> who the push authenticates as
#   gh's active account                        -> who the CLI and API act as
# gh has no per-repository account -- it is one global value per host, which
# another terminal can change under you. That is why the first 'use' snapshots
# it and 'restore' puts it back, and why 'check' verifies it every time.
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'capture', 'define', 'use', 'list', 'forget', 'restore',
                 'protect', 'unprotect',
                 # Older spellings. Kept working because already-installed
                 # pre-push hooks invoke '-Action check'.
                 'save', 'install-hook', 'uninstall-hook')]
    [Alias('Action')]
    [string]$Command = 'check',

    [Parameter(Position = 1)]
    [Alias('Profile')]
    [string]$Name,

    # 'define' only: the profile whose values become the starting defaults.
    [string]$From,

    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'

# git reports "this key is not set" with exit code 1. That is an answer, not a
# failure, and PowerShell 7.4+ would otherwise make it terminating.
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$aliases = @{ 'save' = 'capture'; 'install-hook' = 'protect'; 'uninstall-hook' = 'unprotect' }
if ($aliases.ContainsKey($Command)) { $Command = $aliases[$Command] }

$repoRoot = Resolve-Path "$PSScriptRoot\..\.."
$gitDir   = Join-Path $repoRoot '.git'
if (-not (Test-Path $gitDir)) { throw "not a git repository: $repoRoot" }

if (-not $ConfigPath) { $ConfigPath = Join-Path $gitDir 'fork-identity.json' }
$snapshotPath = Join-Path $gitDir 'fork-identity-backup.json'
$SELF = '.\contrib\fork\identity.ps1'

$KEYS = @{
    name  = 'user.name'
    email = 'user.email'
    cred  = 'credential.https://github.com.username'
}
$LABELS = @{ name = 'Commit name'; email = 'Commit email'; cred = 'GitHub username' }

function Read-JsonFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    return Get-Content $path -Raw | ConvertFrom-Json
}

function Write-JsonFile([string]$path, $value) {
    $value | ConvertTo-Json -Depth 6 | Set-Content $path -Encoding UTF8
}

# $null means "this clone sets nothing", which restore must reproduce as an
# unset key rather than as an empty string.
function Get-LocalConfig([string]$key) {
    $v = & git -C $repoRoot config --local --get $key
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v.Trim()
}

# What git would actually use here, including a value inherited from global
# config. A fresh clone sets nothing locally, and "remember how this machine is
# right now" has to work there -- that is the entire point of 'capture'.
function Get-EffectiveConfig([string]$key) {
    $v = & git -C $repoRoot config --get $key
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v.Trim()
}

function Set-LocalConfig([string]$key, $value) {
    if ($null -eq $value) {
        & git -C $repoRoot config --local --unset-all $key 2>$null | Out-Null
    } else {
        & git -C $repoRoot config --local $key $value
        if ($LASTEXITCODE -ne 0) { throw "could not set $key" }
    }
}

function Test-GhPresent { return [bool](Get-Command gh -ErrorAction SilentlyContinue) }

function Get-ActiveGhUser {
    if (-not (Test-GhPresent)) { return $null }
    $u = gh api user --jq .login 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($u)) { return $null }
    return $u.Trim()
}

# Every account gh has a token for on github.com. Used to suggest real values
# in 'define' and to show in 'list', never to decide anything.
function Get-GhAccounts {
    if (-not (Test-GhPresent)) { return @() }
    $out = gh auth status 2>&1 | Out-String
    $found = [regex]::Matches($out, 'account\s+(\S+)') | ForEach-Object { $_.Groups[1].Value }
    return @($found | Select-Object -Unique)
}

# 'local' reads only what this clone sets -- the snapshot depends on that, since
# it has to restore absence faithfully. 'effective' includes inherited values.
function Get-Identity([string]$scope = 'local') {
    $read = if ($scope -eq 'effective') { 'Get-EffectiveConfig' } else { 'Get-LocalConfig' }
    return [ordered]@{
        name   = & $read $KEYS.name
        email  = & $read $KEYS.email
        cred   = & $read $KEYS.cred
        ghUser = Get-ActiveGhUser
    }
}

function Format-Identity($id) {
    $n = if ($id.name) { $id.name } else { 'unset' }
    $e = if ($id.email) { $id.email } else { 'unset' }
    $g = if ($id.ghUser) { $id.ghUser } else { 'none' }
    return "$n <$e>  gh:$g"
}

function Get-Profiles {
    $cfg = Read-JsonFile $ConfigPath
    if ($null -eq $cfg) { return @{} }
    $out = @{}
    foreach ($p in $cfg.PSObject.Properties) { $out[$p.Name] = $p.Value }
    return $out
}

function Get-Profile([string]$wanted) {
    $all = Get-Profiles
    if ($all.ContainsKey($wanted)) { return $all[$wanted] }
    $known = if ($all.Keys.Count) { ($all.Keys | Sort-Object) -join ', ' } else { 'none yet' }
    throw "Expected a profile named '$wanted', but this clone has: $known." +
          [Environment]::NewLine + "  fix: $SELF capture $wanted"
}

function Save-Profile([string]$profileName, $id) {
    $all = Get-Profiles
    $all[$profileName] = $id
    Write-JsonFile $ConfigPath $all
    Write-Host "Saved '$profileName': $(Format-Identity $id)"
}

# --- commands ----------------------------------------------------------------

function Invoke-Capture {
    if (-not $Name) { throw "Which profile? e.g. $SELF capture work" }
    $id = Get-Identity 'effective'
    if (-not $id.name -or -not $id.email) {
        throw "Expected this machine to have a git identity to capture, but user.name " +
              "and user.email are both unset." + [Environment]::NewLine +
              "  fix: git config --global user.name ""Your Name""" + [Environment]::NewLine +
              "       git config --global user.email ""you@example.com"""
    }
    Save-Profile $Name $id
    Write-Host "That is how this machine is configured right now."
    Write-Host "  next: $SELF define <other-profile> -From $Name"
}

function Invoke-Forget {
    if (-not $Name) { throw "Which profile? e.g. $SELF forget scratch" }
    $all = Get-Profiles
    if (-not $all.ContainsKey($Name)) { Write-Host "No profile '$Name' to forget."; return }
    $all.Remove($Name)
    Write-JsonFile $ConfigPath $all
    Write-Host "Forgot '$Name'. This changed no git config -- use 'restore' for that."
}

function Read-Field([string]$label, $current, [string]$hint) {
    $shown = if ($current) { $current } else { 'none' }
    $suffix = if ($hint) { "  ($hint)" } else { '' }
    $answer = Read-Host "  $($label.PadRight(16)) [$shown]$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $current }
    if ($answer.Trim() -eq '-') { return $null }
    return $answer.Trim()
}

function Invoke-Define {
    if (-not $Name) { throw "Which profile? e.g. $SELF define fork -From work" }
    $seed = if ($From) { Get-Profile $From } else { Get-Identity 'effective' }
    $src  = if ($From) { "profile '$From'" } else { 'this machine' }
    $accounts = Get-GhAccounts
    $hint = if ($accounts.Count) { 'gh knows: ' + ($accounts -join ', ') } else { '' }

    Write-Host "Defining '$Name', starting from $src."
    Write-Host "Enter keeps the value shown; '-' clears it."
    Write-Host ""
    try {
        $id = [ordered]@{
            name  = Read-Field $LABELS.name  $seed.name  ''
            email = Read-Field $LABELS.email $seed.email ''
            cred  = Read-Field $LABELS.cred  $seed.cred  $hint
        }
    } catch {
        throw "'define' needs an interactive console. On a non-interactive one, " +
              "configure the identity with git config and then: $SELF capture $Name"
    }
    $id['ghUser'] = $id.cred
    Write-Host ""
    Save-Profile $Name $id
    Write-Host "  next: $SELF use $Name"
}

# Taken once, before anything changes, and never overwritten -- otherwise a
# second switch would record the first switch's state as "original".
function Save-Snapshot {
    if (Test-Path $snapshotPath) { return }
    $snap = Get-Identity 'local'
    $snap['takenAt'] = (Get-Date).ToString('o')
    Write-JsonFile $snapshotPath $snap
    Write-Host "Remembered how this clone was found ('$SELF restore' undoes everything)."
}

function Set-GhUser($who, [bool]$warn) {
    if (-not $who -or -not (Test-GhPresent)) { return }
    gh auth switch -u $who 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -and $warn) {
        Write-Host "WARNING: gh is not logged in as '$who', so it was not switched."
        Write-Host "         Commits will be authored correctly; gh commands will not be."
        Write-Host "  fix: gh auth login -u $who"
    }
}

function Invoke-Use {
    if (-not $Name) { throw "Which profile? e.g. $SELF use fork" }
    $p = Get-Profile $Name
    Save-Snapshot
    Set-LocalConfig $KEYS.name  $p.name
    Set-LocalConfig $KEYS.email $p.email
    Set-LocalConfig $KEYS.cred  $p.cred
    Set-GhUser $p.ghUser $true
    Write-Host "Now '$Name': $(Format-Identity (Get-Identity 'local'))"
}

function Invoke-Restore {
    $snap = Read-JsonFile $snapshotPath
    if ($null -eq $snap) {
        Write-Host "Nothing to undo -- this clone was never switched."
        return
    }
    Set-LocalConfig $KEYS.name  $snap.name
    Set-LocalConfig $KEYS.email $snap.email
    Set-LocalConfig $KEYS.cred  $snap.cred
    Set-GhUser $snap.ghUser $false
    Remove-Item $snapshotPath -Force
    Write-Host "Restored: $(Format-Identity (Get-Identity 'local'))"
}

function Show-GhState {
    if (-not (Test-GhPresent)) {
        Write-Host "  gh         not installed (optional; commit identity still works)"
        return
    }
    $active   = Get-ActiveGhUser
    $accounts = Get-GhAccounts
    $listed   = if ($accounts.Count) { $accounts -join ', ' } else { 'none logged in' }
    Write-Host "  gh         active: $(if ($active) { $active } else { 'none' })   known: $listed"
}

function Invoke-List {
    $all = Get-Profiles
    if (-not $all.Keys.Count) {
        Write-Host "No profiles yet."
        Write-Host "  fix: $SELF capture work"
    } else {
        foreach ($k in ($all.Keys | Sort-Object)) {
            Write-Host ("  {0,-10} {1}" -f $k, (Format-Identity $all[$k]))
        }
    }
    Write-Host ""
    Write-Host "  active     $(Format-Identity (Get-Identity 'effective'))"
    if (Test-Path $snapshotPath) {
        Write-Host "  found as   $(Format-Identity (Read-JsonFile $snapshotPath))   (restorable)"
    }
    Show-GhState
    $guard = if (Test-Path (Get-HookPath)) { 'on' } else { "off    ($SELF protect)" }
    Write-Host "  push guard $guard"
}

# --- the guard ---------------------------------------------------------------

function Assert-Field([string]$field, $actual, $expected, [string]$target) {
    if ($actual -eq $expected) { return }
    $was = if ($actual) { "'$actual'" } else { 'nothing' }
    throw "Expected $($KEYS[$field]) to be '$expected', but this clone has $was." +
          [Environment]::NewLine + "  fix: $SELF use $target"
}

function Assert-GhAccount($expected, $actual, [string]$target) {
    if (-not $expected) { return }
    # gh is optional everywhere else, so it cannot be mandatory here. A profile
    # always carries a ghUser (define derives it from the username), so without
    # this the guard would refuse on every machine that has no gh -- and the
    # pre-push hook would block every push on one. Say it was skipped: a check
    # that did not run must never read as a check that passed.
    if (-not (Test-GhPresent)) {
        Write-Host "  note: gh is not installed, so its account was not checked."
        return
    }
    if ($actual -eq $expected) { return }
    $was = if ($actual) { "'$actual'" } else { 'no signed-in account' }
    throw "Expected gh to be signed in as '$expected', but it is $was. " +
          "gh's active account is global to this machine, so another terminal may " +
          "have changed it." + [Environment]::NewLine + "  fix: $SELF use $target"
}

# The two ways a correct identity still pushes somewhere wrong.
function Assert-RemoteSafety($p) {
    if ($p.ghUser) {
        $origin = & git -C $repoRoot config --get remote.origin.url
        if ($LASTEXITCODE -eq 0 -and $origin -and $origin -notmatch [regex]::Escape($p.ghUser)) {
            throw "Expected origin to belong to '$($p.ghUser)', but it is '$origin'."
        }
    }
    # Only meaningful when the remote exists at all.
    $null = & git -C $repoRoot remote get-url upstream 2>$null
    if ($LASTEXITCODE -ne 0) { return }

    # An UNSET push URL is not safe: git then pushes to the fetch URL, which for
    # this remote is the upstream repository. Absent must fail the same way a
    # wrong value does, or a fresh clone is unprotected precisely because nobody
    # has configured it yet.
    $pushUrl = & git -C $repoRoot config --get remote.upstream.pushurl
    $isSet = ($LASTEXITCODE -eq 0 -and $pushUrl)
    if (-not $isSet -or $pushUrl.Trim() -ne 'DISABLED') {
        $was = if ($isSet) { "'$($pushUrl.Trim())'" } else { 'unset, so it falls back to the fetch URL' }
        throw "Expected upstream pushes to be DISABLED, but it is $was." +
              [Environment]::NewLine + "  fix: git remote set-url --push upstream DISABLED"
    }
}

function Invoke-Check {
    $target = if ($Name) { $Name } else { 'fork' }
    if (-not (Get-Profiles).Keys.Count) {
        throw "Expected this clone to have identity profiles, but it has none, so " +
              "nothing can be verified." + [Environment]::NewLine +
              "  fix: $SELF capture $target"
    }
    $p  = Get-Profile $target
    $id = Get-Identity 'local'
    foreach ($f in 'name', 'email', 'cred') { Assert-Field $f $id[$f] $p.$f $target }
    Assert-GhAccount $p.ghUser $id.ghUser $target
    Assert-RemoteSafety $p
    Write-Host "OK [$target]: $(Format-Identity $id)"
}

# --- pre-push hook -----------------------------------------------------------
# 'check' by hand only protects the pushes you remember. The hook protects all
# of them. .git/hooks is per-clone and never committed, so it is installed
# rather than shipped.
$HOOK_MARKER = 'fork-identity-guard'
$HOOK_BODY = @'
#!/bin/sh
# fork-identity-guard: installed by contrib/fork/identity.ps1 protect
# Remove with: .\contrib\fork\identity.ps1 unprotect
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
guard="$root/contrib/fork/identity.ps1"

# Not every branch carries the tooling -- master is a pristine mirror of
# upstream and has no contrib/fork/. Never block a push from a branch with no
# guard to run; sync-fork.ps1 checks up front for exactly that case.
[ -f "$guard" ] || exit 0

if command -v pwsh >/dev/null 2>&1; then ps=pwsh; else ps=powershell; fi
if ! "$ps" -NoProfile -ExecutionPolicy Bypass -File "$guard" check; then
    echo "" >&2
    echo "Push stopped by the fork identity guard (above)." >&2
    echo "Override this one push with: git push --no-verify" >&2
    exit 1
fi
exit 0
'@

function Get-HookPath {
    $dir = & git -C $repoRoot rev-parse --git-path hooks
    if ($LASTEXITCODE -ne 0) { throw "could not locate the hooks directory" }
    if (-not [System.IO.Path]::IsPathRooted($dir)) { $dir = Join-Path $repoRoot $dir }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'pre-push')
}

function Invoke-Protect {
    $path = Get-HookPath
    if ((Test-Path $path) -and ((Get-Content $path -Raw) -notmatch $HOOK_MARKER)) {
        throw "A pre-push hook this script did not write already exists at $path."
    }
    # sh rejects a CRLF script with "bad interpreter", and this file's own line
    # endings depend on how git checked it out.
    [System.IO.File]::WriteAllText($path, ($HOOK_BODY -replace "`r`n", "`n"))
    Write-Host "Push guard on. Every 'git push' from this clone now checks first."
    Write-Host "  bypass once: git push --no-verify"
    Write-Host "  turn off:    $SELF unprotect"
}

function Invoke-Unprotect {
    $path = Get-HookPath
    if (-not (Test-Path $path)) { Write-Host "Push guard is already off."; return }
    if ((Get-Content $path -Raw) -notmatch $HOOK_MARKER) {
        throw "The pre-push hook at $path was not written by this script -- leaving it alone."
    }
    Remove-Item $path -Force
    Write-Host "Push guard off."
}

switch ($Command) {
    'check'     { Invoke-Check }
    'capture'   { Invoke-Capture }
    'define'    { Invoke-Define }
    'use'       { Invoke-Use }
    'list'      { Invoke-List }
    'forget'    { Invoke-Forget }
    'restore'   { Invoke-Restore }
    'protect'   { Invoke-Protect }
    'unprotect' { Invoke-Unprotect }
}
