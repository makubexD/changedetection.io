# Turning a generated watch.json into a watch that actually works -- checking
# it, applying it, and proving it checked.
#
# WHY Test-WatchPlan EXISTS. Several watch fields fail QUIETLY: a bad CSS
# selector imports fine and only breaks on the first real check; a
# time_schedule_limit missing a weekday key throws deep inside the scheduler,
# hours after the watch was created; a filter on a Restock watch is silently
# never read. None of this is caught by the API's own validation, which is
# stricter about types than about these judgement calls. This module is the
# one place that knows the difference between "invalid JSON" (the API's job)
# and "valid JSON that describes a watch which cannot work" (this file's job).

Import-Module (Join-Path $PSScriptRoot 'Console.psm1')

# Fields the model computes or manages itself. Sending any of these is either
# ignored or actively wrong -- model/schema_utils.py strips most on write, but
# a generator should never produce them in the first place.
$script:ReadOnlyFields = @(
    'uuid', 'history', 'history_n', 'has_history', 'viewed', 'has_unviewed',
    'link', 'open_link', 'last_changed', 'newest_history_key', 'label',
    'previous_md5', 'check_count', 'fetch_time', 'last_checked', 'last_error',
    'date_created', 'page_title', 'content-type', 'remote_server_reply',
    'consecutive_filter_failures', 'browser_steps_last_error_step',
    'notification_alert_count', 'last_notification_error', 'restock',
    'llm_evaluation_cache', 'llm_prefilter', 'llm_last_tokens_used',
    'llm_tokens_used_cumulative', 'llm_tokens_this_period', 'llm_tokens_period_key'
)

# conditions/__init__.py's registered field choices. A condition on any other
# field name passes the API's schema check and then blocks every future change
# forever, because json_logic reads a missing var as falsy. See
# conditions/default_plugin.py, levenshtein_plugin.py, wordcount_plugin.py.
$script:ConditionFields = @(
    'extracted_number', 'page_filtered_text', 'levenshtein_ratio',
    'levenshtein_distance', 'word_count'
)

$script:Weekdays = @('monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday')

function Test-ReadOnlyFieldsAbsent($Plan, [System.Collections.ArrayList]$Problems) {
    foreach ($field in $script:ReadOnlyFields) {
        if ($Plan.PSObject.Properties.Name -contains $field) {
            [void]$Problems.Add("'$field' is computed by the app, not something to set -- remove it.")
        }
    }
}

function Test-IntervalConsistent($Plan, [System.Collections.ArrayList]$Problems) {
    if ($Plan.time_between_check_use_default -ne $false) { return }
    $tbc = $Plan.time_between_check
    $units = @('weeks', 'days', 'hours', 'minutes', 'seconds')
    $anySet = $tbc -and ($units | Where-Object { $tbc.$_ -and [int]$tbc.$_ -gt 0 }).Count -gt 0
    if (-not $anySet) {
        [void]$Problems.Add(
            "time_between_check_use_default is false but time_between_check has no unit " +
            "greater than 0 -- the API rejects this with a 400. Set at least one unit, or " +
            "drop time_between_check_use_default to inherit the global interval.")
    }
}

function Test-ScheduleLimitShape($Plan, [System.Collections.ArrayList]$Problems) {
    $limit = $Plan.time_schedule_limit
    if (-not $limit -or -not $limit.enabled) { return }
    foreach ($day in $script:Weekdays) {
        if ($limit.PSObject.Properties.Name -notcontains $day) {
            [void]$Problems.Add(
                "time_schedule_limit.enabled is true but '$day' is missing -- the scheduler " +
                "looks up every weekday by its lowercase English name and throws on a gap. " +
                "All seven of $($script:Weekdays -join ', ') must be present.")
        }
    }
    Test-ScheduleDurationsAreStrings $limit $Problems
}

function Test-ScheduleDurationsAreStrings($Limit, [System.Collections.ArrayList]$Problems) {
    foreach ($day in $script:Weekdays) {
        $entry = $Limit.$day
        if (-not $entry -or -not $entry.duration) { continue }
        foreach ($unit in @('hours', 'minutes')) {
            $value = $entry.duration.$unit
            if ($null -ne $value -and $value -isnot [string]) {
                [void]$Problems.Add(
                    "time_schedule_limit.$day.duration.$unit is $($value.GetType().Name), " +
                    "not a string -- the form field stores these as strings ('24', not 24); " +
                    "an API POST with a number here fails validation.")
            }
        }
    }
}

function Test-GetHasNoBody($Plan, [System.Collections.ArrayList]$Problems) {
    $method = if ($Plan.method) { $Plan.method } else { 'GET' }
    if ($method -eq 'GET' -and $Plan.body) {
        [void]$Problems.Add("method is GET but 'body' is set -- the form rejects this; drop the body or change method.")
    }
}

function Test-SubtractiveSelectorsNoJson($Plan, [System.Collections.ArrayList]$Problems) {
    foreach ($rule in @($Plan.subtractive_selectors)) {
        if ($rule -like 'json:*') {
            [void]$Problems.Add("subtractive_selectors contains '$rule' -- JSONPath is not permitted there, only CSS and XPath.")
        }
    }
}

function Test-RestockHasNoFilter($Plan, [System.Collections.ArrayList]$Problems) {
    if ($Plan.processor -ne 'restock_diff') { return }
    if (@($Plan.include_filters).Count -gt 0) {
        [void]$Problems.Add(
            "processor is restock_diff but include_filters is set -- the Restock & Price " +
            "processor reads the whole page's structured data and never looks at the filter. " +
            "Either drop the filter, or switch processor to text_json_diff if you need one.")
    }
}

function Test-ConditionFieldsKnown($Plan, [System.Collections.ArrayList]$Problems) {
    foreach ($cond in @($Plan.conditions)) {
        if (-not $cond.field) { continue }
        if ($cond.field -notin $script:ConditionFields) {
            [void]$Problems.Add(
                "condition field '$($cond.field)' is not registered -- a missing var evaluates " +
                "falsy in every check, which BLOCKS THE WATCH FOREVER, not just this rule. " +
                "Known fields: $($script:ConditionFields -join ', ').")
        }
    }
}

# Runs every check above and refuses once, with every problem found, rather
# than stopping at the first -- a plan is usually fixed by hand in one pass,
# not by re-running this five times to uncover the next issue.
function Test-WatchPlan($Plan) {
    $problems = [System.Collections.ArrayList]::new()
    Test-ReadOnlyFieldsAbsent $Plan $problems
    Test-IntervalConsistent $Plan $problems
    Test-ScheduleLimitShape $Plan $problems
    Test-GetHasNoBody $Plan $problems
    Test-SubtractiveSelectorsNoJson $Plan $problems
    Test-RestockHasNoFilter $Plan $problems
    Test-ConditionFieldsKnown $Plan $problems
    if ($problems.Count -eq 0) { return }
    $text = ($problems | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    throw (New-Refusal "The plan has $($problems.Count) problem(s) that would fail silently or at the API:`n$text" `
                       "fix the field(s) named above, or ask the skill to regenerate them")
}

function Invoke-WatchPlanPost([string]$BaseUrl, [string]$ApiKey, $Plan) {
    $body = $Plan | ConvertTo-Json -Depth 20
    $headers = @{ 'x-api-key' = $ApiKey }
    try {
        $response = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/v1/watch" `
                                       -Headers $headers -ContentType 'application/json' -Body $body
    } catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw (New-Refusal "POST /api/v1/watch failed: $detail" `
                           "check the API key in Settings -> API, and that the app is reachable at $BaseUrl")
    }
    return $response.uuid
}

# The API takes processor_config_<name> as one key INSIDE the watch JSON
# (api/Watch.py splits it out on the way in); the restore ZIP wants it as a
# SEPARATE file, {"<name>": {...}}, next to watch.json (Watch.py:148-153 reads
# it back that way). One plan, two shapes -- this is the one place that
# reshapes it, so the skill only ever has to write the API's shape.
function Export-WatchPlanZip([string]$OutFile, $Plan) {
    $uuid = [guid]::NewGuid().ToString()
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) "watchplan-$uuid"
    $watchDir = Join-Path $stage $uuid
    New-Item -ItemType Directory -Path $watchDir -Force | Out-Null
    try {
        $watch = [ordered]@{}
        $configKey = if ($Plan.processor) { "processor_config_$($Plan.processor)" } else { $null }
        foreach ($prop in $Plan.PSObject.Properties) {
            if ($prop.Name -ne $configKey) { $watch[$prop.Name] = $prop.Value }
        }
        ([pscustomobject]$watch) | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $watchDir 'watch.json') -Encoding utf8
        if ($configKey -and ($Plan.PSObject.Properties.Name -contains $configKey)) {
            $configFile = Join-Path $watchDir "$($Plan.processor).json"
            (@{ $Plan.processor = $Plan.$configKey } | ConvertTo-Json -Depth 20) | Set-Content -Path $configFile -Encoding utf8
        }
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
        Compress-Archive -Path $watchDir -DestinationPath $OutFile
    } finally {
        Remove-Item -Recurse -Force $stage
    }
    return $uuid
}

function Get-WatchState([string]$BaseUrl, [string]$ApiKey, [string]$Uuid) {
    return Invoke-RestMethod -Method Get -Uri "$BaseUrl/api/v1/watch/$Uuid" -Headers @{ 'x-api-key' = $ApiKey }
}

# Forces the check the API only QUEUES, then waits for it to actually land
# before claiming anything about what the watch saw. ?recheck=true returns as
# soon as the item is queued, not when the fetch finishes -- reading
# history/latest immediately would show the PREVIOUS snapshot, or nothing on a
# brand-new watch, and either looks like success.
function Invoke-WatchRecheckAndReport([string]$BaseUrl, [string]$ApiKey, [string]$Uuid, [int]$TimeoutSec) {
    $before = Get-WatchState $BaseUrl $ApiKey $Uuid
    $recheckUri = "$BaseUrl/api/v1/watch/$Uuid" + '?recheck=true'
    Invoke-RestMethod -Method Get -Uri $recheckUri -Headers @{ 'x-api-key' = $ApiKey } | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $after = $before
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $after = Get-WatchState $BaseUrl $ApiKey $Uuid
        if ($after.last_checked -gt $before.last_checked) { break }
    }
    Show-WatchCheckResult $BaseUrl $ApiKey $Uuid $before $after $TimeoutSec
}

function Show-WatchCheckResult([string]$BaseUrl, [string]$ApiKey, [string]$Uuid, $Before, $After, [int]$TimeoutSec) {
    if ($After.last_checked -le $Before.last_checked) {
        throw (New-Refusal "The forced recheck had not landed after ${TimeoutSec}s." `
                           "the queue may be busy, or the site is slow/blocking -- $BaseUrl/edit/$Uuid, or re-run with a longer -TimeoutSec")
    }
    if ($After.last_error) {
        throw (New-Refusal "The watch checked, but the last check failed: $($After.last_error)" `
                           "$BaseUrl/edit/$Uuid -- Preview shows the filtered text, which is usually why")
    }
    Write-Pass 'checked' "$BaseUrl/edit/$Uuid"
    if ($After.processor_config_restock_diff_source -and $After.PSObject.Properties.Name -contains 'restock') {
        Write-Host "  restock: $($After.restock | ConvertTo-Json -Compress)"
    }
    $snapshot = Invoke-RestMethod -Method Get -Uri "$BaseUrl/api/v1/watch/$Uuid/history/latest" -Headers @{ 'x-api-key' = $ApiKey } -ErrorAction SilentlyContinue
    if ($snapshot) {
        $preview = if ($snapshot.Length -gt 300) { $snapshot.Substring(0, 300) + ' ...' } else { $snapshot }
        Write-Host "  captured: $preview"
    }
}

Export-ModuleMember -Function Test-WatchPlan, Invoke-WatchPlanPost, Export-WatchPlanZip, Invoke-WatchRecheckAndReport
