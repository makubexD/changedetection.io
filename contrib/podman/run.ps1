# Run changedetection.io under rootless Podman, then open it in a browser.
# Usage: .\contrib\podman\run.ps1 [-Tag dev] [-Port 5000]
param(
    [string]$Tag = 'dev',
    [int]$Port = 5000
)
$ErrorActionPreference = 'Stop'

$image = "changedetection.io:$Tag"
$name  = 'changedetection'

# Replace any previous container of the same name; the named volume,
# and therefore every watch and its history, is untouched by this.
podman rm -f $name 2>$null | Out-Null

podman run -d `
    --name $name `
    --restart unless-stopped `
    -p "127.0.0.1:${Port}:5000" `
    -v changedetection-data:/datastore `
    -e "BASE_URL=http://localhost:$Port" `
    $image
if ($LASTEXITCODE -ne 0) { throw "podman run failed with exit code $LASTEXITCODE" }

Write-Host "changedetection.io is starting on http://localhost:$Port"
Write-Host "Follow the logs with: .\contrib\podman\logs.ps1"
