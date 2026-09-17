# Console output shared by every command, so that a stage, a pass and a refusal
# look the same whichever command produced them.

function Write-Stage([string]$Name) {
    Write-Host ""
    Write-Host "-- $Name" -ForegroundColor Cyan
}

function Write-Pass([string]$Name, [string]$Detail) {
    $line = if ($Detail) { "{0,-10} {1}" -f $Name, $Detail } else { $Name }
    Write-Host "OK    $line" -ForegroundColor Green
}

function Write-Warn([string]$Name, [string]$Detail) {
    $line = if ($Detail) { "{0,-10} {1}" -f $Name, $Detail } else { $Name }
    Write-Host "WARN  $line" -ForegroundColor Yellow
}

function Write-Fail([string]$Name, [string]$Detail) {
    $line = if ($Detail) { "{0,-10} {1}" -f $Name, $Detail } else { $Name }
    Write-Host "FAIL  $line" -ForegroundColor Red
}

# Every refusal names its own fix on a 'fix:' line. Used by throw sites so that
# the shape is identical everywhere and a reader learns to look for it once.
function New-Refusal([string]$Problem, [string]$Fix) {
    $text = $Problem
    if ($Fix) { $text += [Environment]::NewLine + "  fix: $Fix" }
    return $text
}

# Was this error a deliberate refusal, or did something genuinely break?
#
# Worth telling apart because the two deserve OPPOSITE treatment: a refusal
# should be printed as written and nothing else, while a fault is only useful
# with its file, line and stack attached. Prettifying both would hide real bugs
# behind a friendly sentence.
#
# `throw "some text"` is the shape every refusal in this CLI uses, and it sets
# TargetObject to that same string. Nothing else does: a null-dereference, a bad
# cast, a thrown exception OBJECT, divide-by-zero and command-not-found all leave
# TargetObject null, and Get-Content on a missing path sets it to the PATH, which
# is why the message is compared too rather than merely tested for being a string.
function Test-IsRefusal($ErrorRecord) {
    return ($ErrorRecord.TargetObject -is [string]) -and
           ($ErrorRecord.Exception.Message -ceq [string]$ErrorRecord.TargetObject)
}

# PowerShell will not print a multi-line refusal legibly, whichever $ErrorView is
# set: ConciseView folds the newlines into one row -- so a message written as
# problem / fix / detail arrives as a run-on sentence with the fix buried in the
# middle of it -- and NormalView keeps them but adds CategoryInfo and
# FullyQualifiedErrorId on top. So the message is printed here instead.
#
# The first line takes the FAIL shape every other failure in this CLI uses. The
# rest go out VERBATIM: they already carry the author's own indent ('  fix: ...'),
# and re-indenting them to line up under the header would destroy the one visual
# cue that marks the fix.
function Write-Refusal([string]$Name, [string]$Message) {
    # @() because -split on a single-line message returns a STRING, and indexing
    # a string walks its characters.
    $lines = @($Message -split "`r?`n")
    Write-Fail $Name $lines[0]
    # Guarded, not $lines[1..($lines.Count-1)]: on a one-line message that range
    # is 1..0, which PowerShell counts DOWNWARDS and so prints line 0 a second
    # time. Every single-line refusal in the CLI would have doubled.
    for ($i = 1; $i -lt $lines.Count; $i++) {
        Write-Host $lines[$i] -ForegroundColor Red
    }
}

# The actions a run actually TOOK, as opposed to the narrative it printed on the
# way past. A long run scrolls; this is the part worth keeping, rendered once at
# the end as one timestamped block.
#
# $global:, not $script:. Every command does Import-Module -Force, which
# re-initialises module scope -- so a list held there would be wiped the moment
# 'app update' handed over to 'app start', losing everything recorded before it.
if (-not $global:MakuActions) { $global:MakuActions = [System.Collections.ArrayList]::new() }

# State CHANGES only. "The image is current" is an observation and belongs in the
# narrative above; only things still true after the run ends belong in here.
function Add-Action([string]$Verb, [string]$Detail) {
    [void]$global:MakuActions.Add([pscustomobject]@{ At = Get-Date; Verb = $Verb; Detail = $Detail })
}

# Renders and CLEARS, and the clearing is the load-bearing half: 'app update'
# hands off to a relaunched child process, and the dispatcher calls this too.
# Draining makes a double-printed record structurally impossible rather than
# something each caller has to remember not to cause.
function Write-ActionLog {
    if ($global:MakuActions.Count -eq 0) { return }
    Write-Stage 'actions taken'
    foreach ($a in $global:MakuActions) {
        Write-Host ("  {0}  {1,-10} {2}" -f $a.At.ToString('HH:mm:ss'), $a.Verb, $a.Detail)
    }
    $global:MakuActions.Clear()
}

Export-ModuleMember -Function Write-Stage, Write-Pass, Write-Warn, Write-Fail, `
                              New-Refusal, Test-IsRefusal, Write-Refusal, `
                              Add-Action, Write-ActionLog
