# Switch this clone between GitHub identities, and put the machine back exactly
# as it was found.
#
#   .\contrib\fork\identity.ps1                      # check (the default)
#   .\contrib\fork\identity.ps1 -Action list
#   .\contrib\fork\identity.ps1 -Action save    -Profile fork
#   .\contrib\fork\identity.ps1 -Action use     -Profile fork
#   .\contrib\fork\identity.ps1 -Action restore
#
# NO IDENTIFIERS LIVE IN THIS FILE. The fork is public, so names, emails and
# usernames are read from a per-clone file at .git\fork-identity.json --
# inside .git, which is never committed, so there is no way to leak one by
# accident. 'save' writes it from whatever is configured right now, which is
# the whole bootstrap on a new machine.
#
# IT ONLY EVER WRITES REPO-LOCAL GIT CONFIG. Your global user.name/user.email
# are never touched, so nothing outside this clone changes and every other
# repository on the machine keeps working as before.
#
# THE ONE MACHINE-WIDE THING is gh's active account, which is global by
# design. So the first switch snapshots what was active beforehand -- along
# with the repo-local config as it was found, including which keys were
# ABSENT -- and 'restore' puts all of it back, unsetting what was unset rather
# than guessing a value for it.
param(
    [ValidateSet('check', 'use', 'save', 'list', 'restore', 'install-hook', 'uninstall-hook')]
    [string]$Action = 'check',
    [string]$Profile,
    # Override where profiles are stored. Defaults to .git\fork-identity.json.
    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'

# git reports "this key is not set" with exit code 1. That is an answer, not a
# failure, and PowerShell 7.4+ would otherwise turn it into a terminating error.
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repoRoot = Resolve-Path "$PSScriptRoot\..\.."
$gitDir   = Join-Path $repoRoot '.git'
if (-not (Test-Path $gitDir)) { throw "not a git repository: $repoRoot" }

if (-not $ConfigPath) { $ConfigPath = Join-Path $gitDir 'fork-identity.json' }
$snapshotPath = Join-Path $gitDir 'fork-identity-backup.json'

$KEYS = @{
    name  = 'user.name'
    email = 'user.email'
    cred  = 'credential.https://github.com.username'
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    return Get-Content $path -Raw | ConvertFrom-Json
}

function Write-JsonFile([string]$path, $value) {
    $value | ConvertTo-Json -Depth 6 | Set-Content $path -Encoding UTF8
}

# $null means "not set in this clone", which restore must reproduce as an
# unset key rather than as an empty string.
function Get-LocalConfig([string]$key) {
    $v = & git -C $repoRoot config --local --get $key
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

function Get-ActiveGhUser {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }
    $u = gh api user --jq .login 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($u)) { return $null }
    return $u.Trim()
}

function Get-CurrentIdentity {
    return [ordered]@{
        name   = Get-LocalConfig $KEYS.name
        email  = Get-LocalConfig $KEYS.email
        cred   = Get-LocalConfig $KEYS.cred
        ghUser = Get-ActiveGhUser
    }
}

# Taken once, before anything is changed, and never overwritten -- otherwise a
# second switch would record the first switch's state as "original".
function Save-Snapshot {
    if (Test-Path $snapshotPath) { return }
    $snap = Get-CurrentIdentity
    $snap['takenAt'] = (Get-Date).ToString('o')
    Write-JsonFile $snapshotPath $snap
    Write-Host "Recorded how this clone was found (restore with -Action restore)."
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
    if (-not $all.ContainsKey($wanted)) {
        $known = if ($all.Keys.Count) { ($all.Keys | Sort-Object) -join ', ' } else { '(none yet)' }
        throw "No profile '$wanted'. Known: $known. " +
              "Configure that identity, then: .\contrib\fork\identity.ps1 -Action save -Profile $wanted"
    }
    return $all[$wanted]
}

function Format-Identity($id) {
    $n = if ($id.name) { $id.name } else { '(unset)' }
    $e = if ($id.email) { $id.email } else { '(unset)' }
    $g = if ($id.ghUser) { $id.ghUser } else { '(none)' }
    return "$n <$e>  gh:$g"
}

function Invoke-Save {
    if (-not $Profile) { throw "-Profile is required for 'save'." }
    $id = Get-CurrentIdentity
    if (-not $id.name -or -not $id.email) {
        throw "This clone has no local user.name/user.email to save. Set them first:`n" +
              "    git -C `"$repoRoot`" config --local user.name  `"Your Name`"`n" +
              "    git -C `"$repoRoot`" config --local user.email `"you@example.com`""
    }
    $all = Get-Profiles
    $all[$Profile] = $id
    Write-JsonFile $ConfigPath $all
    Write-Host "Saved profile '$Profile': $(Format-Identity $id)"
    Write-Host "Stored in $ConfigPath (inside .git -- never committed)."
}

function Invoke-Use {
    if (-not $Profile) { throw "-Profile is required for 'use'." }
    $p = Get-Profile $Profile
    Save-Snapshot

    Set-LocalConfig $KEYS.name  $p.name
    Set-LocalConfig $KEYS.email $p.email
    Set-LocalConfig $KEYS.cred  $p.cred

    if ($p.ghUser -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        gh auth switch -u $p.ghUser 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: could not switch gh to '$($p.ghUser)'. Commits will be"
            Write-Host "         authored correctly, but pushes may use the wrong account."
            Write-Host "         Fix with: gh auth login -u $($p.ghUser)"
        }
    }
    Write-Host "Now using '$Profile': $(Format-Identity (Get-CurrentIdentity))"
}

function Invoke-Restore {
    $snap = Read-JsonFile $snapshotPath
    if ($null -eq $snap) {
        Write-Host "Nothing to restore -- this clone was never switched."
        return
    }
    Set-LocalConfig $KEYS.name  $snap.name
    Set-LocalConfig $KEYS.email $snap.email
    Set-LocalConfig $KEYS.cred  $snap.cred

    if ($snap.ghUser -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        gh auth switch -u $snap.ghUser 2>&1 | Out-Null
    }
    Remove-Item $snapshotPath -Force
    Write-Host "Restored to how this clone was found: $(Format-Identity (Get-CurrentIdentity))"
    Write-Host "(snapshot cleared -- the next switch records a fresh one)"
}

function Invoke-List {
    $all = Get-Profiles
    Write-Host "Profiles in $ConfigPath"
    if (-not $all.Keys.Count) {
        Write-Host "    (none yet -- see -Action save)"
    } else {
        foreach ($k in ($all.Keys | Sort-Object)) {
            Write-Host ("    {0,-10} {1}" -f $k, (Format-Identity $all[$k]))
        }
    }
    Write-Host ""
    Write-Host "Currently:  $(Format-Identity (Get-CurrentIdentity))"
    if (Test-Path $snapshotPath) {
        $snap = Read-JsonFile $snapshotPath
        Write-Host "Found as:   $(Format-Identity $snap)   (restorable)"
    }
}

# The push guard. Everything it checks is a way to push as the wrong account,
# or to push somewhere you did not mean to.
function Invoke-Check {
    $target = if ($Profile) { $Profile } else { 'fork' }
    $all = Get-Profiles
    if (-not $all.Keys.Count) {
        throw "No profiles configured yet for this clone. Set the identity you want, then:`n" +
              "    .\contrib\fork\identity.ps1 -Action save -Profile $target`n" +
              "See contrib/fork/README.md."
    }
    $p  = Get-Profile $target
    $id = Get-CurrentIdentity

    foreach ($f in 'name', 'email', 'cred') {
        if ($id[$f] -ne $p.$f) {
            throw "WRONG $($KEYS[$f]): '$($id[$f])' -- expected '$($p.$f)'. " +
                  "Run: .\contrib\fork\identity.ps1 -Action use -Profile $target"
        }
    }
    if ($p.ghUser -and $id.ghUser -ne $p.ghUser) {
        throw "WRONG GH ACCOUNT: '$($id.ghUser)' -- expected '$($p.ghUser)'. " +
              "Run: .\contrib\fork\identity.ps1 -Action use -Profile $target"
    }

    Assert-RemoteSafety $p
    Write-Host "OK [$target]: $(Format-Identity $id)  ($repoRoot)"
}

# The two ways a correct identity still pushes to the wrong place: an origin
# belonging to somebody else, and an upstream that will accept a push.
function Assert-RemoteSafety($p) {
    if ($p.ghUser) {
        $origin = & git -C $repoRoot config --get remote.origin.url
        if ($LASTEXITCODE -eq 0 -and $origin -and $origin -notmatch [regex]::Escape($p.ghUser)) {
            throw "ORIGIN '$origin' does not belong to '$($p.ghUser)' -- " +
                  "this clone would push somewhere that profile does not own."
        }
    }
    $pushUrl = & git -C $repoRoot config --get remote.upstream.pushurl
    if ($LASTEXITCODE -eq 0 -and $pushUrl -and $pushUrl.Trim() -ne 'DISABLED') {
        throw "UPSTREAM PUSH IS ENABLED ('$pushUrl') -- a push could reach the upstream repo. " +
              "Run: git remote set-url --push upstream DISABLED"
    }
}

# --- pre-push hook -----------------------------------------------------------
# Running 'check' by hand only protects the pushes you remember to protect. A
# pre-push hook protects all of them, including a plain 'git push' typed from
# an editor. Hooks live in .git/hooks, which is per-clone and never committed,
# so this has to be installed rather than shipped.
$HOOK_MARKER = 'fork-identity-guard'
$HOOK_BODY = @'
#!/bin/sh
# fork-identity-guard: installed by contrib/fork/identity.ps1 -Action install-hook
# Remove with: .\contrib\fork\identity.ps1 -Action uninstall-hook
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
guard="$root/contrib/fork/identity.ps1"

# Not every branch carries the tooling -- master is a pristine mirror of
# upstream and has no contrib/fork/. Never block a push from a branch that has
# no guard to run; sync-fork.ps1 checks up front for exactly that case.
[ -f "$guard" ] || exit 0

if command -v pwsh >/dev/null 2>&1; then ps=pwsh; else ps=powershell; fi
if ! "$ps" -NoProfile -ExecutionPolicy Bypass -File "$guard" -Action check; then
    echo "" >&2
    echo "pre-push blocked by the fork identity guard (above)." >&2
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

function Invoke-InstallHook {
    $path = Get-HookPath
    if ((Test-Path $path) -and ((Get-Content $path -Raw) -notmatch $HOOK_MARKER)) {
        throw "A pre-push hook this script did not write already exists at $path. " +
              "Move it aside, or merge the guard into it by hand."
    }
    # sh will not run a script with CRLF line endings -- "bad interpreter" -- and
    # this file's own endings depend on how git checked it out.
    [System.IO.File]::WriteAllText($path, ($HOOK_BODY -replace "`r`n", "`n"))
    Write-Host "Installed the pre-push guard at $path"
    Write-Host "Every 'git push' from this clone now runs the identity check first."
    Write-Host "Bypass one push with: git push --no-verify"
    Write-Host "Remove it with:       .\contrib\fork\identity.ps1 -Action uninstall-hook"
}

function Invoke-UninstallHook {
    $path = Get-HookPath
    if (-not (Test-Path $path)) { Write-Host "No pre-push hook is installed."; return }
    if ((Get-Content $path -Raw) -notmatch $HOOK_MARKER) {
        throw "The pre-push hook at $path was not written by this script -- leaving it alone."
    }
    Remove-Item $path -Force
    Write-Host "Removed the pre-push guard from $path"
}

switch ($Action) {
    'check'   { Invoke-Check }
    'use'     { Invoke-Use }
    'save'    { Invoke-Save }
    'list'    { Invoke-List }
    'restore' { Invoke-Restore }
    'install-hook'   { Invoke-InstallHook }
    'uninstall-hook' { Invoke-UninstallHook }
}
