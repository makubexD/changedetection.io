# Follow the changedetection.io container logs.
# Usage: .\contrib\podman\logs.ps1 [-Tail 100] [-Browser]
#
# -Browser follows the sockpuppetbrowser container instead. Chrome crashes show
# up there and nowhere else -- the app only sees a failed fetch.
param(
    [int]$Tail = 100,
    [switch]$Browser
)
$ErrorActionPreference = 'Stop'

$name = if ($Browser) { 'browser-sockpuppet-chrome' } else { 'changedetection' }
podman logs --tail $Tail -f $name
