param(
  [Parameter(Mandatory = $true)]
  [string]$NodeName,

  [Parameter(Mandatory = $true)]
  [string]$NodeIp,

  [int]$PrefixLength = 24,

  [string]$HostOnlyInterface = "enp0s3",

  [string]$NatInterface = "enp0s8",

  [Parameter(Mandatory = $true)]
  [string]$SshPublicKeyPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputIso
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$Content
  )

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-TextOrThrow {
  param([string]$Path)

  if (Test-Path -LiteralPath $Path) {
    return (Get-Content -LiteralPath $Path -Raw).Trim()
  }

  if ($Path -match '^/mnt/[a-z]/') {
    $content = wsl bash -lc "cat '$Path'" 2>$null
    if ($LASTEXITCODE -eq 0 -and $content) {
      return ($content -join "`n").Trim()
    }
  }

  throw "Cannot read SSH public key from '$Path'"
}

function To-WslPath {
  param([string]$Path)

  if ($Path -match '^/mnt/[a-z]/') {
    return $Path
  }

  $fullPath = $Path
  if ($Path -notmatch '^[A-Za-z]:\\') {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
  }
  $fullPath = [System.IO.Path]::GetFullPath($fullPath)
  $fullPath = $fullPath -replace "\\", "/"

  $wslPath = wsl wslpath -a "$fullPath"
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to convert path to WSL format: $Path"
  }
  return $wslPath.Trim()
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cloudInitDir = Resolve-Path (Join-Path $scriptDir "..\cloud-init")

$userTpl = Get-Content -LiteralPath (Join-Path $cloudInitDir "user-data.tpl") -Raw
$metaTpl = Get-Content -LiteralPath (Join-Path $cloudInitDir "meta-data.tpl") -Raw
$netTpl  = Get-Content -LiteralPath (Join-Path $cloudInitDir "network-config.tpl") -Raw

$pubKey = Get-TextOrThrow -Path $SshPublicKeyPath

$userData = $userTpl.Replace("__SSH_PUBLIC_KEY__", $pubKey).Replace("__NODE_IP__", $NodeIp).Replace("__PREFIX_LENGTH__", [string]$PrefixLength).Replace("__HOSTONLY_IF__", $HostOnlyInterface).Replace("__NAT_IF__", $NatInterface)
$metaData = $metaTpl.Replace("__INSTANCE_ID__", $NodeName).Replace("__HOSTNAME__", $NodeName)
$netData = $netTpl.Replace("__NODE_IP__", $NodeIp).Replace("__PREFIX_LENGTH__", [string]$PrefixLength).Replace("__HOSTONLY_IF__", $HostOnlyInterface).Replace("__NAT_IF__", $NatInterface)

$outputDir = Split-Path -Parent $OutputIso
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$userDataPath = Join-Path $outputDir "user-data"
$metaDataPath = Join-Path $outputDir "meta-data"
$netDataPath  = Join-Path $outputDir "network-config"

Write-Utf8NoBom -Path $userDataPath -Content $userData
Write-Utf8NoBom -Path $metaDataPath -Content $metaData
Write-Utf8NoBom -Path $netDataPath  -Content $netData

$outputDirWsl = To-WslPath -Path $outputDir
$outputIsoWsl = To-WslPath -Path $OutputIso
$linuxCmd = @"
set -euo pipefail
cd '$outputDirWsl'
if command -v cloud-localds >/dev/null 2>&1; then
  cloud-localds --network-config=network-config '$outputIsoWsl' user-data meta-data
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -output '$outputIsoWsl' -volid cidata -joliet -rock user-data meta-data network-config >/dev/null 2>&1
else
  echo 'Missing cloud-localds or genisoimage in WSL' >&2
  exit 1
fi
"@
wsl bash -lc $linuxCmd
if ($LASTEXITCODE -ne 0) {
  throw "Failed to build seed ISO for $NodeName"
}

Write-Host "seed.iso generated: $OutputIso"
