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

Export-ModuleMember -Function Write-Stage, Write-Pass, Write-Warn, Write-Fail, New-Refusal
