# Repository-level helpers shared by every command.
#
# Everything here answers a question about THIS clone: where it is, whether it
# is clean, what branch it is on. Nothing here knows about podman or identity.

# git answers questions through exit codes rather than only reporting failure
# with them -- "this key is not set" is exit 1, and that is an answer. PowerShell
# 7.4+ turns any non-zero native exit code into a terminating error, which would
# make those answers unreachable. Exit codes are checked by hand instead.
#
# Called once by maku.ps1, rather than copy-pasted into every script as before.
function Use-NativeExitCodes {
    if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
        Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Global
    }
}

# The working tree root. Asked of git rather than derived from $PSScriptRoot so
# that a linked worktree resolves to the worktree, not to the main checkout.
function Get-RepoRoot {
    $root = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $root) {
        throw "Not a git repository. Run this from inside the changedetection.io clone."
    }
    return (Resolve-Path $root.Trim()).Path
}

# The directory shared by every worktree -- where hooks and config actually live.
# In a linked worktree .git is a FILE, so joining '.git' to the root gives a path
# that cannot be written to; --git-common-dir is the only correct answer.
function Get-GitCommonDir {
    $dir = & git rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $dir) { throw "Could not locate the git directory." }
    $dir = $dir.Trim()
    if (-not [System.IO.Path]::IsPathRooted($dir)) { $dir = Join-Path (Get-RepoRoot) $dir }
    return (Resolve-Path $dir).Path
}

function Get-CurrentBranch {
    $branch = & git rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not read the current branch." }
    $branch = $branch.Trim()
    if ($branch -eq 'HEAD') {
        throw "HEAD is detached -- check out the branch you are working on first."
    }
    return $branch
}

# Only TRACKED changes are the problem: those are what make a branch switch fail
# halfway and leave you somewhere unexpected. Untracked files ride along
# harmlessly, and refusing over them would mean every machine had to exclude its
# own editor and tool config before anything here would run.
#
# One definition, used by both 'fork sync' and 'app update'. Previously these
# were two copies that disagreed -- update.ps1 counted untracked files, sync did
# not -- so the same dirty tree was accepted by one and refused by the other.
function Assert-CleanTree {
    $dirty = & git status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0) { throw "Not a git repository." }
    if ($dirty) {
        # -join, because $dirty is an ARRAY and PowerShell interpolates one with
        # SPACES -- so every changed path arrived on a single run-on line.
        throw ("Working tree has uncommitted changes -- commit or stash first:" +
               [Environment]::NewLine + ($dirty -join [Environment]::NewLine))
    }
}

Export-ModuleMember -Function Use-NativeExitCodes, Get-RepoRoot, Get-GitCommonDir,
                              Get-CurrentBranch, Assert-CleanTree
