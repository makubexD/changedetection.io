# This clone's identity: who authors its commits, and which GitHub account its
# pushes authenticate as.
#
# IT IS ALL PLAIN GIT CONFIG, DELIBERATELY. There used to be a profile store in
# .git/fork-identity.json with capture/define/use/list/forget/restore commands
# around it, to switch identity inside one clone. Nothing needs that: a clone
# belongs to ONE account permanently -- this fork is always its owner's, a work
# checkout is always the work account's. What you switch is gh's active account,
# which is a machine-wide mode and gh's own business.
#
# So the identity lives in .git/config, which is per-clone, never tracked, and
# already the place git looks. No bespoke store, no snapshot, no second format.
#
# NO NAMES OR EMAILS ARE IN THIS FILE. The fork is public, and anything committed
# here is published permanently -- history, forks, mirrors, scrapers.

Import-Module (Join-Path $PSScriptRoot 'Repo.psm1')

$script:Keys = @{
    Name          = 'user.name'
    Email         = 'user.email'
    Account       = 'credential.https://github.com.username'
    UseConfigOnly = 'user.useConfigOnly'
}

function Get-LocalConfig([string]$Key) {
    $value = & git config --local --get $Key 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value.Trim()
}

function Set-LocalConfig([string]$Key, $Value) {
    if ($null -eq $Value) {
        & git config --local --unset-all $Key 2>$null | Out-Null
    } else {
        & git config --local $Key $Value
        if ($LASTEXITCODE -ne 0) { throw "could not set $Key" }
    }
}

# What git would actually use here, global config included. The difference
# between this and the local reading is the whole point: a value that is only
# EFFECTIVE is inherited from the machine, and on a machine whose global identity
# is a work account, inheriting is exactly the failure to catch.
function Get-EffectiveConfig([string]$Key) {
    $value = & git config --get $Key 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value.Trim()
}

function Get-RepoIdentity {
    return [pscustomobject]@{
        Name             = Get-LocalConfig $script:Keys.Name
        Email            = Get-LocalConfig $script:Keys.Email
        Account          = Get-LocalConfig $script:Keys.Account
        UseConfigOnly    = Get-LocalConfig $script:Keys.UseConfigOnly
        InheritedName    = Get-EffectiveConfig $script:Keys.Name
        InheritedEmail   = Get-EffectiveConfig $script:Keys.Email
        InheritedAccount = Get-EffectiveConfig $script:Keys.Account
    }
}

function Set-RepoIdentity([string]$Name, [string]$Email, [string]$Account) {
    Set-LocalConfig $script:Keys.Name    $Name
    Set-LocalConfig $script:Keys.Email   $Email
    Set-LocalConfig $script:Keys.Account $Account
    # Stops git inventing an identity from hostname and username when a value is
    # missing. It does NOT stop inheritance of an explicitly-set global value --
    # that is what the commit-range check in the guard is for.
    Set-LocalConfig $script:Keys.UseConfigOnly 'true'
}

function Clear-RepoIdentity {
    foreach ($key in $script:Keys.Values) { Set-LocalConfig $key $null }
}

# The account that owns the repository this clone pushes to, read from the URL
# rather than configured separately -- one less thing to keep in step, and it is
# what the guard compares the destination against.
function Get-RemoteOwner([string]$Url) {
    if (-not $Url) { return $null }
    # https://host/owner/repo(.git)  |  https://user@host/owner/repo  |  git@host:owner/repo
    if ($Url -match '^[a-zA-Z]+://(?:[^@/]+@)?[^/]+/([^/]+)/') { return $Matches[1] }
    if ($Url -match '^[^@]+@[^:]+:([^/]+)/')                   { return $Matches[1] }
    return $null
}

function Get-OriginUrl {
    $url = & git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $url) { return $null }
    return $url.Trim()
}

# Every remote whose URL points at a repository this clone does not own, so the
# guard can refuse a push to any of them -- not only to one literally named
# 'upstream', which is all the old check looked at.
function Get-ForeignRemotes([string]$Account) {
    $names = & git remote 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $names) { return @() }
    $out = foreach ($name in @($names)) {
        $name = $name.Trim()
        if (-not $name) { continue }
        $url   = (& git config --get "remote.$name.url" 2>$null)
        $owner = Get-RemoteOwner $url
        if ($owner -and $Account -and $owner -ieq $Account) { continue }
        $push = & git config --get "remote.$name.pushurl" 2>$null
        [pscustomobject]@{
            Name = $name; Url = $url; Owner = $owner
            PushUrl = $(if ($LASTEXITCODE -eq 0) { $push } else { $null })
        }
    }
    return @($out)
}

Export-ModuleMember -Function Get-RepoIdentity, Set-RepoIdentity, Clear-RepoIdentity,
                              Get-RemoteOwner, Get-OriginUrl, Get-ForeignRemotes,
                              Get-LocalConfig, Set-LocalConfig, Get-EffectiveConfig
