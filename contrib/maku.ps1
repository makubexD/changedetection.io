<#
.SYNOPSIS
    The one entry point for this fork's tooling.

.DESCRIPTION
    Grammar:  maku <resource> <action> [options]

    The resource says what you are operating on, the action says what you are
    doing to it, and options only modify that operation. Once you know a few
    commands you can guess the rest, which is the point.

    Run with no arguments to see every resource and action, or with just a
    resource to see that resource's actions.

    NO param() BLOCK, DELIBERATELY. A declared parameter block makes PowerShell
    bind every -Flag itself, so it rejects "-WithBrowser" as an unknown parameter
    before the command ever sees it -- and ValueFromRemainingArguments does not
    help, because a token starting with '-' is read as a parameter name. With no
    param block everything arrives in $args verbatim and is handed straight
    through, so commands own their own options and this file needs to know none
    of them.

.EXAMPLE
    .\contrib\maku.ps1
.EXAMPLE
    .\contrib\maku.ps1 app start -WithBrowser
.EXAMPLE
    .\contrib\maku.ps1 tests run -Suite unit
#>
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\Cli.psm1') -Force
# For Test-IsRefusal / Write-Refusal at the dispatch below. Commands import this
# themselves too; -Force makes the repeat harmless.
Import-Module (Join-Path $PSScriptRoot 'lib\Console.psm1') -Force
Use-NativeExitCodes

$CommandRoot = Join-Path $PSScriptRoot 'commands'
$Resource = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$Action   = if ($args.Count -ge 2) { [string]$args[1] } else { '' }
# [object[]] is load-bearing: a one-element slice unrolls to a STRING, and an
# if-as-expression unrolls it again even when the branch wraps it in @().
[object[]]$Rest = @()
if ($args.Count -gt 2) { $Rest = $args[2..($args.Count - 1)] }

# Resources and actions are DISCOVERED from the directory tree, not listed here.
# Adding commands/<resource>/<action>.ps1 makes it appear in help and become
# runnable with no edit to this file.
function Get-Resources {
    # A directory with no command files is a resource under construction, not a
    # resource -- listing it would advertise something that cannot be run.
    return @(Get-ChildItem -Path $CommandRoot -Directory -ErrorAction SilentlyContinue |
             Where-Object { Get-ChildItem -Path $_.FullName -Filter '*.ps1' -ErrorAction SilentlyContinue } |
             Sort-Object Name | Select-Object -ExpandProperty Name)
}

function Get-Actions([string]$res) {
    return @(Get-ChildItem -Path (Join-Path $CommandRoot $res) -Filter '*.ps1' -ErrorAction SilentlyContinue |
             Sort-Object Name | ForEach-Object { $_.BaseName })
}

# Each command file's first line is "#: <one-line summary>". Reading it here is
# what keeps help and behaviour from drifting apart -- there is no second list of
# descriptions to forget to update.
function Get-Summary([string]$res, [string]$act) {
    $first = Get-Content (Join-Path $CommandRoot "$res\$act.ps1") -TotalCount 1 -ErrorAction SilentlyContinue
    if ($first -match '^#:\s*(.+)$') { return $Matches[1].Trim() }
    return ''
}

function Show-Resource([string]$res) {
    foreach ($act in (Get-Actions $res)) {
        Write-Host ("  {0,-9} {1,-9} {2}" -f $res, $act, (Get-Summary $res $act))
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "  maku <resource> <action> [options]"
    Write-Host ""
    # @() re-wraps deliberately: PowerShell unrolls a one-element array on
    # return, and indexing the resulting STRING walks its characters instead.
    $all = @(Get-Resources)
    for ($i = 0; $i -lt $all.Count; $i++) {
        Show-Resource $all[$i]
        if ($i -lt $all.Count - 1) { Write-Host "" }
    }
    Write-Host ""
    Write-Host "  Detail on any command:  Get-Help .\contrib\commands\<resource>\<action>.ps1 -Full"
    Write-Host ""
}

if (-not $Resource) { Show-Help; exit 0 }

$resources = @(Get-Resources)
if ($Resource -notin $resources) {
    Write-Host "Unknown resource '$Resource'." -ForegroundColor Red
    Write-Host "  known: $($resources -join ', ')"
    exit 2
}

# A resource with no action lists its actions rather than erroring. Exploring by
# typing half a command is how the grammar teaches itself.
if (-not $Action) {
    Write-Host ""
    Show-Resource $Resource
    Write-Host ""
    exit 0
}

$actions = @(Get-Actions $Resource)
if ($Action -notin $actions) {
    Write-Host "Unknown action '$Action' for '$Resource'." -ForegroundColor Red
    Write-Host "  known: $($actions -join ', ')"
    exit 2
}

$script = Join-Path $CommandRoot "$Resource\$Action.ps1"

# Bound by name against the command's own metadata -- see lib/Cli.psm1 for why
# this cannot just be `& $script @Rest`.
try {
    $bound = ConvertTo-CommandArguments $script $Rest
} catch {
    Write-Host "$Resource $Action`: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
$positional = $bound.Positional
$named      = $bound.Named

# Commands refuse by throwing, and PowerShell renders a thrown message badly
# enough to defeat the point of writing one -- see Write-Refusal. Catching it
# HERE rather than in each command is what makes every refusal in the CLI look
# the same, including ones added later, and it extends what this file already
# does a few lines above for argument-binding errors.
try {
    & $script @positional @named
    # Captured BEFORE anything else runs. Only native commands set $LASTEXITCODE,
    # but the record below is one call away from shelling out, and a dispatcher
    # that silently reported the wrong exit code would be very hard to notice.
    $code = $LASTEXITCODE
    Write-ActionLog
    exit $code
} catch {
    # BEFORE the message, so the refusal stays the last thing on screen. A run
    # that died halfway is exactly when what it had already done matters most --
    # which is why this is on the failure path at all, not only the happy one.
    Write-ActionLog
    if (Test-IsRefusal $_) {
        Write-Refusal "$Resource $Action" $_.Exception.Message
    } else {
        # Deliberately NOT prettified. The file, line and stack are the entire
        # value of an unexpected fault, and a friendly sentence would discard
        # exactly the part that makes it fixable.
        Write-Host "$Resource $Action failed unexpectedly -- this is a bug in the CLI." -ForegroundColor Red
        Write-Host ($_ | Out-String)
    }
    # 1, the same code an uncaught throw already produced, so anything gating on
    # it is unaffected. 2 stays the usage-error code used above.
    exit 1
}
