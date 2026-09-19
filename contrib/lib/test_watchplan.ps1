#: run WatchPlan.psm1's own tests -- standalone, no container, no Pester

<#
.SYNOPSIS
    Test-WatchPlan's accept/refuse cases, in the same style as
    contrib/runtime/test_probe.py: plain checks, no framework, runnable directly.

.DESCRIPTION
    Every check builds the smallest plan that could trigger the rule, plus one
    that must NOT trigger it -- a validator that only has positive fixtures
    would pass just as well with the check deleted.

.EXAMPLE
    pwsh -File contrib\lib\test_watchplan.ps1
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WatchPlan.psm1') -Force

$script:Failures = [System.Collections.ArrayList]::new()

function Check([string]$Label, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) {
        Write-Host "ok   $Label"
    } else {
        Write-Host "FAIL $Label" -ForegroundColor Red
        if ($Detail) { Write-Host "     $Detail" -ForegroundColor Red }
        [void]$script:Failures.Add($Label)
    }
}

function Test-PlanRefused($Plan, [string]$Substring) {
    try {
        Test-WatchPlan $Plan
        return @{ Refused = $false; Message = '' }
    } catch {
        return @{ Refused = $true; Message = $_.Exception.Message }
    }
}

# --- a plan with nothing wrong passes clean ----------------------------------

$clean = [pscustomobject]@{ url = 'https://example.com'; processor = 'text_json_diff' }
$result = Test-PlanRefused $clean 'n/a'
Check 'a minimal, correct plan is not refused' (-not $result.Refused) $result.Message

# --- read-only fields ---------------------------------------------------------

$withUuid = [pscustomobject]@{ url = 'https://example.com'; uuid = 'abc-123' }
$result = Test-PlanRefused $withUuid 'uuid'
Check 'a plan carrying uuid is refused' ($result.Refused -and $result.Message -match 'uuid') $result.Message

# --- interval consistency -----------------------------------------------------

$badInterval = [pscustomobject]@{
    url = 'https://example.com'
    time_between_check_use_default = $false
    time_between_check = [pscustomobject]@{ weeks = $null; days = $null; hours = $null; minutes = $null; seconds = $null }
}
$result = Test-PlanRefused $badInterval 'time_between_check'
Check 'use_default:false with every unit empty is refused' $result.Refused $result.Message

$goodInterval = [pscustomobject]@{
    url = 'https://example.com'
    time_between_check_use_default = $false
    time_between_check = [pscustomobject]@{ weeks = $null; days = $null; hours = 6; minutes = $null; seconds = $null }
}
$result = Test-PlanRefused $goodInterval 'n/a'
Check 'use_default:false with one unit set is accepted' (-not $result.Refused) $result.Message

# --- time_schedule_limit weekday keys -----------------------------------------

$missingDay = [pscustomobject]@{
    url = 'https://example.com'
    time_schedule_limit = [pscustomobject]@{
        enabled = $true
        monday = [pscustomobject]@{ enabled = $true; start_time = '00:00'; duration = [pscustomobject]@{ hours = '24'; minutes = '0' } }
        # tuesday .. sunday deliberately missing
    }
}
$result = Test-PlanRefused $missingDay 'tuesday'
Check 'time_schedule_limit missing a weekday key is refused' ($result.Refused -and $result.Message -match 'tuesday') $result.Message

function Full-Week([hashtable]$DurationOverride) {
    $week = [ordered]@{ enabled = $true }
    foreach ($day in @('monday','tuesday','wednesday','thursday','friday','saturday','sunday')) {
        $duration = if ($DurationOverride) { $DurationOverride } else { @{ hours = '24'; minutes = '0' } }
        $week[$day] = [pscustomobject]@{ enabled = $true; start_time = '00:00'; duration = [pscustomobject]$duration }
    }
    return [pscustomobject]$week
}

$completeWeek = [pscustomobject]@{ url = 'https://example.com'; time_schedule_limit = (Full-Week $null) }
$result = Test-PlanRefused $completeWeek 'n/a'
Check 'a complete weekly schedule with string durations is accepted' (-not $result.Refused) $result.Message

# --- duration values must be strings, not numbers -----------------------------

$numericDuration = [pscustomobject]@{ url = 'https://example.com'; time_schedule_limit = (Full-Week @{ hours = 24; minutes = 0 }) }
$result = Test-PlanRefused $numericDuration 'string'
Check 'a numeric duration.hours is refused (must be the string "24", not 24)' ($result.Refused -and $result.Message -match 'string') $result.Message

# --- GET must have no body -----------------------------------------------------

$getWithBody = [pscustomobject]@{ url = 'https://example.com'; method = 'GET'; body = 'x=1' }
$result = Test-PlanRefused $getWithBody 'body'
Check 'GET with a body is refused' $result.Refused $result.Message

$postWithBody = [pscustomobject]@{ url = 'https://example.com'; method = 'POST'; body = 'x=1' }
$result = Test-PlanRefused $postWithBody 'n/a'
Check 'POST with a body is accepted' (-not $result.Refused) $result.Message

# --- subtractive_selectors rejects json: ---------------------------------------

$jsonSubtractive = [pscustomobject]@{ url = 'https://example.com'; subtractive_selectors = @('json:$.foo') }
$result = Test-PlanRefused $jsonSubtractive 'JSONPath'
Check 'a json: subtractive selector is refused' $result.Refused $result.Message

# --- restock_diff must carry no filter -----------------------------------------

$restockWithFilter = [pscustomobject]@{ url = 'https://example.com'; processor = 'restock_diff'; include_filters = @('.price') }
$result = Test-PlanRefused $restockWithFilter 'restock_diff'
Check 'restock_diff with an include_filter is refused -- it is never read' $result.Refused $result.Message

$restockNoFilter = [pscustomobject]@{ url = 'https://example.com'; processor = 'restock_diff'; include_filters = @() }
$result = Test-PlanRefused $restockNoFilter 'n/a'
Check 'restock_diff with no filter is accepted' (-not $result.Refused) $result.Message

# --- condition fields must be registered ----------------------------------------

$unknownCondition = [pscustomobject]@{
    url = 'https://example.com'
    conditions = @([pscustomobject]@{ field = 'page_title'; operator = '=='; value = 'x' })
}
$result = Test-PlanRefused $unknownCondition 'not registered'
Check 'a condition on an unregistered field (page_title is commented out) is refused' $result.Refused $result.Message

$knownCondition = [pscustomobject]@{
    url = 'https://example.com'
    conditions = @([pscustomobject]@{ field = 'extracted_number'; operator = '<'; value = '300' })
}
$result = Test-PlanRefused $knownCondition 'n/a'
Check 'a condition on extracted_number is accepted' (-not $result.Refused) $result.Message

# --- Export-WatchPlanZip: the plan's shape splits into two files -------------

$restockPlan = [pscustomobject]@{
    url = 'https://example.com/product'
    processor = 'restock_diff'
    processor_config_restock_diff = [pscustomobject]@{ price_change_threshold_percent = 2 }
}
$zipPath = Join-Path $env:TEMP "watchplan-test-$([guid]::NewGuid()).zip"
try {
    $uuid = Export-WatchPlanZip $zipPath $restockPlan
    Check 'Export-WatchPlanZip returns a UUID' ([guid]::TryParse($uuid, [ref]([guid]::Empty)))
    Check 'the zip file was written' (Test-Path $zipPath) $zipPath

    $extractDir = Join-Path $env:TEMP "watchplan-extract-$([guid]::NewGuid())"
    Expand-Archive -Path $zipPath -DestinationPath $extractDir
    $watchJsonPath = Join-Path $extractDir "$uuid\watch.json"
    $configJsonPath = Join-Path $extractDir "$uuid\restock_diff.json"
    Check 'watch.json landed under a UUID-named directory' (Test-Path $watchJsonPath) $watchJsonPath
    Check 'processor_config_restock_diff was split into its own file' (Test-Path $configJsonPath) $configJsonPath

    $watchJson = Get-Content $watchJsonPath -Raw | ConvertFrom-Json
    Check 'watch.json does NOT carry the processor_config_* key -- it lives in its own file' `
          ($watchJson.PSObject.Properties.Name -notcontains 'processor_config_restock_diff') $watchJson

    $configJson = Get-Content $configJsonPath -Raw | ConvertFrom-Json
    Check 'the config file is keyed by processor name, matching how the app reads it back' `
          ($configJson.restock_diff.price_change_threshold_percent -eq 2) $configJson

    Remove-Item -Recurse -Force $extractDir
} finally {
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
}

Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host "FAILED -- $($script:Failures.Count) failure(s)" -ForegroundColor Red
    exit 1
} else {
    Write-Host 'PASSED -- 0 failure(s)' -ForegroundColor Green
    exit 0
}
