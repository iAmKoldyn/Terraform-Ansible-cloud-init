param(
  [string]$AnsibleDir = "../ansible",
  [string]$Inventory = "inventory/hosts.ini",
  [string]$Playbook = "playbooks/site.yml",
  [switch]$DisableHostKeyChecking = $true,
  [switch]$RefreshKnownHosts = $true,
  [switch]$AutoRebalanceServices = $true
)

$ErrorActionPreference = "Stop"

function To-WslPath {
  param([string]$WinPath)

  $resolved = (Resolve-Path -LiteralPath $WinPath).Path
  $resolved = [System.IO.Path]::GetFullPath($resolved)
  $resolved = $resolved -replace "\\", "/"
  $wslPath = wsl wslpath -a "$resolved"
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to convert path to WSL: $WinPath"
  }
  return $wslPath.Trim()
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not [System.IO.Path]::IsPathRooted($AnsibleDir)) {
  $AnsibleDir = Join-Path $scriptDir $AnsibleDir
}

$ansibleDirResolved = Resolve-Path $AnsibleDir
$inventoryPath = if ([System.IO.Path]::IsPathRooted($Inventory)) { $Inventory } else { Join-Path $ansibleDirResolved.Path $Inventory }

if ($RefreshKnownHosts) {
  $refreshScript = Join-Path $scriptDir "refresh-known-hosts.ps1"
  & $refreshScript -Inventory $inventoryPath
}

$ansibleDirWsl = To-WslPath $ansibleDirResolved.Path
$ansibleCfgWsl = To-WslPath (Join-Path $ansibleDirResolved.Path "ansible.cfg")

$envExports = "export ANSIBLE_CONFIG='$ansibleCfgWsl'; "
if ($DisableHostKeyChecking) {
  $envExports += "export ANSIBLE_HOST_KEY_CHECKING=False; "
}

$cmd = "cd '$ansibleDirWsl' && $envExports ansible-playbook -i '$Inventory' '$Playbook'"
wsl bash -lc $cmd
if ($LASTEXITCODE -ne 0) {
  throw "Ansible run failed"
}

if ($AutoRebalanceServices) {
  $rebalanceScript = Join-Path $scriptDir "rebalance-swarm-services.ps1"
  try {
    & $rebalanceScript -Inventory $inventoryPath
  } catch {
    Write-Warning ("Auto-rebalance skipped: " + $_.Exception.Message)
  }
}
