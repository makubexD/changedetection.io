#: unset this clone's identity again

<#
.SYNOPSIS
    Remove the repo-local identity keys this tooling set.

.DESCRIPTION
    Unsets user.name, user.email, credential.https://github.com.username and
    user.useConfigOnly for THIS clone only. Global config is never touched.

    AFTERWARDS THIS CLONE COMMITS AS THE MACHINE'S GLOBAL IDENTITY. On a machine
    whose global identity is a work account, that is exactly the thing the guard
    exists to stop, so it says so rather than leaving you to notice.

    The push guard is left installed -- it is what would catch a commit made in
    that state. Remove it deliberately with 'guard disable'.

.EXAMPLE
    .\contrib\maku.ps1 identity reset
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1')  -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Identity.psm1') -Force
Use-NativeExitCodes

if (-not $PSCmdlet.ShouldProcess('this clone', 'unset the local identity keys')) { exit 0 }

Clear-RepoIdentity
$after = Get-RepoIdentity

Write-Pass 'identity' 'local keys unset; global config untouched'
Write-Host ""
Write-Warn 'inherited' "this clone now commits as $($after.InheritedName) <$($after.InheritedEmail)>"
Write-Host "           and pushes as $($after.InheritedAccount)."
Write-Host ""
Write-Host "The push guard is still installed and will refuse commits authored that way."
Write-Host "Remove it too with: .\contrib\maku.ps1 guard disable"
