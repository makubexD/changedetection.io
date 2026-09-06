# Follow the changedetection.io container logs.
# Usage: .\contrib\podman\logs.ps1 [-Tail 100]
param([int]$Tail = 100)
$ErrorActionPreference = 'Stop'
podman logs --tail $Tail -f changedetection
