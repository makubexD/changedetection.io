#: ask a URL what a watch would actually see there

<#
.SYNOPSIS
    Show what changedetection.io would extract from a page, before you build a watch on it.

.DESCRIPTION
    Runs inside the running container and uses the application's OWN extraction
    code, so what it prints is what a watch would do -- not a second
    implementation that can drift from the first.

    It always reports three things, because each is a different way a watch goes
    wrong and the EMPTY case is usually the diagnosis:

      1. which fetcher got the bytes, and what came back
      2. what 'Restock & Price' mode would find, independently of any filter
      3. what your selector matched, and the number a Condition would extract

    Point 2 is the one the UI hides. The restock processor reads the whole page's
    structured data and never looks at the watch's filter, so a page publishing a
    single price reports that price on every watch pointed at it, whatever
    selector is set.

.PARAMETER Url
    The page to probe.

.PARAMETER Selector
    A CSS selector to test, exactly as you would paste it into the watch's
    "CSS/JSONPath/JQ/XPath Filter" box. Optional.

.PARAMETER WithBrowser
    Fetch through the app's Playwright fetcher instead of plain HTTP. Use when
    the element you want is built by JavaScript. Requires the stack to be running
    with -WithBrowser.

.PARAMETER Find
    Text to search for in the fetched content. Prints ranked CSS selector
    candidates for every element that contains it, each with the text it would
    isolate -- for when you do not have a selector yet and want the probe to
    suggest one, rather than testing one you already wrote.

.PARAMETER Json
    Print one JSON report instead of prose. Same underlying facts as the default
    report; for a caller that wants to branch on them rather than parse text.

.EXAMPLE
    .\contrib\maku.ps1 site probe -Url https://tucambista.pe
.EXAMPLE
    .\contrib\maku.ps1 site probe -Url https://tucambista.pe -Selector '.tc-quote-rates button:nth-of-type(2) .tc-quote-rate-value'
.EXAMPLE
    .\contrib\maku.ps1 site probe -Url https://tucambista.pe -Find '3.3'
#>
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$Selector,
    [string]$Find,
    [switch]$WithBrowser,
    [switch]$Json,
    [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Use-NativeExitCodes

Test-PodmanReady
$container = (Get-PodmanNames).App

# The script is not in the image -- it arrives on the read-only mount that
# 'app start' adds. Checking for it by hand turns "python: can't open file" into
# a sentence naming the fix.
& podman exec $container test -f /maku-runtime/probe.py 2>$null
if ($LASTEXITCODE -ne 0) {
    throw (New-Refusal "The container has no /maku-runtime/probe.py, so it is running without the fork's runtime mount." `
                       ".\contrib\maku.ps1 app start -WithBrowser   (restarts with the mount; your watches are untouched)")
}

$probeArgs = @('exec', $container, 'python', '/maku-runtime/probe.py', '--url', $Url, '--timeout', "$TimeoutSec")
if ($Selector)    { $probeArgs += @('--selector', $Selector) }
if ($Find)        { $probeArgs += @('--find', $Find) }
if ($WithBrowser) { $probeArgs += '--with-browser' }
if ($Json)        { $probeArgs += '--json' }

& podman @probeArgs
if ($LASTEXITCODE -ne 0) { throw "probe failed (exit $LASTEXITCODE)." }
