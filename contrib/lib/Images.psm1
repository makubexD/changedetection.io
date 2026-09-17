# The image pins in contrib/images.psd1, and keeping the files that cannot read
# it in step with it.
#
# WHY THIS EXISTS. The browser digest used to be a literal in six files -- three
# scripts, the compose file, the kube manifest and the quadlet unit -- and the
# documented upgrade procedure was "replace the digest in five files". That is a
# procedure nobody performs correctly twice. Here the value has one home, the
# scripts read it, and the three files that cannot are rewritten and verified.

$script:PinFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'images.psd1'

# Matches the digest wherever it appears, including inside a commented-out block
# in the kube manifest -- a commented pin that drifts is a trap for whoever
# uncomments it later.
$script:DigestPattern = 'sockpuppetbrowser@sha256:[0-9a-f]{64}'

function Get-ImageData {
    if (-not (Test-Path $script:PinFile)) { throw "Missing $script:PinFile" }
    return Import-PowerShellDataFile -Path $script:PinFile
}

# Name is one of the keys in images.psd1: AppLocal, AppPublished, Browser.
function Get-ImagePin([string]$Name) {
    $data = Get-ImageData
    if (-not $data.ContainsKey($Name)) {
        throw "No image named '$Name'. Known: $(($data.Keys | Where-Object { $_ -ne 'BrowserMirrors' } | Sort-Object) -join ', ')"
    }
    return $data[$Name]
}

# What each mirror file currently carries, so both 'show' and 'verify' work from
# one reading rather than two slightly different ones.
function Get-BrowserPinState {
    $data     = Get-ImageData
    $expected = $data.Browser
    $root     = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Not a git repository." }
    $root = $root.Trim()

    $rows = foreach ($rel in $data.BrowserMirrors) {
        $path = Join-Path $root $rel
        if (-not (Test-Path $path)) {
            [pscustomobject]@{ File = $rel; Found = $null; Agrees = $false; Note = 'missing' }
            continue
        }
        $hits = @([regex]::Matches((Get-Content $path -Raw), $script:DigestPattern) |
                  ForEach-Object { $_.Value } | Select-Object -Unique)
        if ($hits.Count -eq 0) {
            [pscustomobject]@{ File = $rel; Found = $null; Agrees = $false; Note = 'no digest found' }
        } elseif ($hits.Count -gt 1) {
            [pscustomobject]@{ File = $rel; Found = ($hits -join ', '); Agrees = $false; Note = 'disagrees with itself' }
        } else {
            $agrees = $expected.EndsWith($hits[0])
            [pscustomobject]@{ File = $rel; Found = $hits[0]; Agrees = $agrees
                               Note = if ($agrees) { 'ok' } else { 'differs' } }
        }
    }
    return [pscustomobject]@{ Expected = $expected; Files = @($rows) }
}

function Test-ImagePins {
    $state = Get-BrowserPinState
    return -not ($state.Files | Where-Object { -not $_.Agrees })
}

# Rewrites images.psd1 and every mirror to the new digest. Whole-file rewrite of
# one exact pattern, so a file carrying the digest twice is corrected in both
# places rather than half-updated.
function Set-ImagePin([string]$Digest) {
    if ($Digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "Expected a digest like sha256:<64 hex chars>, got '$Digest'."
    }
    $data = Get-ImageData
    $root = (& git rev-parse --show-toplevel).Trim()
    $new  = "sockpuppetbrowser@$Digest"
    $touched = @()

    foreach ($rel in (@($script:PinFile) + ($data.BrowserMirrors | ForEach-Object { Join-Path $root $_ }))) {
        if (-not (Test-Path $rel)) { continue }
        $body = Get-Content $rel -Raw
        $next = [regex]::Replace($body, $script:DigestPattern, $new)
        if ($next -ne $body) {
            # -NoNewline: Get-Content -Raw keeps the trailing newline, so Set-Content
            # would otherwise add a second one on every pin.
            Set-Content -Path $rel -Value $next -NoNewline -Encoding UTF8
            $touched += $rel.Replace("$root/", '').Replace("$root\", '')
        }
    }
    return $touched
}

Export-ModuleMember -Function Get-ImagePin, Get-BrowserPinState, Test-ImagePins, Set-ImagePin
