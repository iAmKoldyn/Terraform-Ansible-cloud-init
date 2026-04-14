[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Inventory = "../ansible/inventory/hosts.ini",
  [string]$SshUser = "",
  [string]$ManagerAddress = "",
  [string]$LabelKey = "com.kp.auto_rebalance",
  [string]$LabelValue = "true",
  [int]$ConnectTimeoutSeconds = 5
)

$ErrorActionPreference = "Stop"

function Get-InventoryVar {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  foreach ($line in (Get-Content -LiteralPath $Path)) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed.StartsWith("[")) {
      continue
    }

    if ($trimmed -like "$Name=*") {
      return $trimmed.Substring($Name.Length + 1)
    }
  }

  return $null
}

function Get-InventoryGroupHosts {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$GroupName
  )

  $hosts = @()
  $currentGroup = ""

  foreach ($line in (Get-Content -LiteralPath $Path)) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#")) {
      continue
    }

    if ($trimmed -match '^\[(.+)\]$') {
      $currentGroup = $Matches[1]
      continue
    }

    if ($currentGroup -ne $GroupName) {
      continue
    }

    $parts = $trimmed -split "\s+"
    if ($parts.Count -lt 2) {
      continue
    }

    $name = $parts[0]
    $address = $null
    foreach ($part in $parts[1..($parts.Count - 1)]) {
      if ($part -like "ansible_host=*") {
        $address = $part.Substring("ansible_host=".Length)
        break
      }
    }

    if ($address) {
      $hosts += [PSCustomObject]@{
        Name    = $name
        Address = $address
      }
    }
  }

  return $hosts
}

function Invoke-SshCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [string]$Command,

    [int]$TimeoutSeconds = 5
  )

  $output = & ssh `
    -o "BatchMode=yes" `
    -o "StrictHostKeyChecking=accept-new" `
    -o "ConnectTimeout=$TimeoutSeconds" `
    $Target $Command 2>&1

  if ($LASTEXITCODE -ne 0) {
    throw (($output | Out-String).Trim())
  }

  return @($output)
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not [System.IO.Path]::IsPathRooted($Inventory)) {
  $Inventory = Join-Path $scriptDir $Inventory
}

$inventoryResolved = (Resolve-Path -LiteralPath $Inventory).Path

if ([string]::IsNullOrWhiteSpace($SshUser)) {
  $SshUser = Get-InventoryVar -Path $inventoryResolved -Name "ansible_user"
}

if ([string]::IsNullOrWhiteSpace($SshUser)) {
  throw "Could not determine SSH user. Pass -SshUser or define ansible_user in inventory."
}

$managerCandidates = @()
if (-not [string]::IsNullOrWhiteSpace($ManagerAddress)) {
  $managerCandidates += [PSCustomObject]@{
    Name    = $ManagerAddress
    Address = $ManagerAddress
  }
}
$managerCandidates += Get-InventoryGroupHosts -Path $inventoryResolved -GroupName "managers"

if (-not $managerCandidates) {
  throw "No manager nodes found in inventory."
}

$reachableManager = $null
$nodeLines = @()

foreach ($manager in $managerCandidates | Sort-Object -Property Address -Unique) {
  $target = "$SshUser@$($manager.Address)"
  try {
    $probe = Invoke-SshCommand -Target $target -TimeoutSeconds $ConnectTimeoutSeconds -Command "docker node ls --format '{{.Hostname}}|{{.Status}}|{{.Availability}}|{{.ManagerStatus}}'"
    $reachableManager = [PSCustomObject]@{
      Name    = $manager.Name
      Address = $manager.Address
      Target  = $target
    }
    $nodeLines = $probe
    break
  } catch {
  }
}

if (-not $reachableManager) {
  Write-Host "Auto-rebalance skipped: no reachable swarm manager."
  exit 0
}

$readyWorkers = @(
  $nodeLines |
    ForEach-Object {
      $parts = $_ -split "\|", 4
      if ($parts.Count -eq 4 -and [string]::IsNullOrWhiteSpace($parts[3]) -and $parts[1] -eq "Ready" -and $parts[2] -eq "Active") {
        $parts[0]
      }
    } |
    Where-Object { $_ }
)

if ($readyWorkers.Count -lt 2) {
  Write-Host "Auto-rebalance skipped: fewer than two ready worker nodes."
  exit 0
}

$filter = "label=$LabelKey=$LabelValue"
$serviceLines = Invoke-SshCommand `
  -Target $reachableManager.Target `
  -TimeoutSeconds $ConnectTimeoutSeconds `
  -Command "docker service ls --filter '$filter' --format '{{.Name}}|{{.Mode}}|{{.Replicas}}'"

$serviceLines = @($serviceLines | Where-Object { $_ })
if (-not $serviceLines) {
  Write-Host "Auto-rebalance skipped: no services matched label $LabelKey=$LabelValue."
  exit 0
}

$servicesToUpdate = @()
foreach ($line in $serviceLines) {
  $parts = $line -split "\|", 3
  if ($parts.Count -ne 3) {
    continue
  }

  $serviceName = $parts[0]
  $mode = $parts[1]
  $replicas = $parts[2]

  if ($mode -ne "replicated") {
    continue
  }

  $desiredReplicas = 0
  if ($replicas -match '/(\d+)$') {
    $desiredReplicas = [int]$Matches[1]
  }

  if ($desiredReplicas -lt $readyWorkers.Count) {
    continue
  }

  $taskLines = Invoke-SshCommand `
    -Target $reachableManager.Target `
    -TimeoutSeconds $ConnectTimeoutSeconds `
    -Command "docker service ps '$serviceName' --filter desired-state=running --format '{{.Node}}|{{.CurrentState}}'"

  $runningNodes = @(
    $taskLines |
      ForEach-Object {
        $taskParts = $_ -split "\|", 2
        if ($taskParts.Count -eq 2 -and $taskParts[1] -like "Running*") {
          $taskParts[0]
        }
      } |
      Where-Object { $_ } |
      Sort-Object -Unique
  )

  $missingWorkers = @($readyWorkers | Where-Object { $runningNodes -notcontains $_ })
  if ($missingWorkers.Count -gt 0) {
    $servicesToUpdate += [PSCustomObject]@{
      Name           = $serviceName
      MissingWorkers = ($missingWorkers -join ", ")
    }
  }
}

if (-not $servicesToUpdate) {
  Write-Host "Auto-rebalance skipped: labeled services are already distributed across ready workers."
  exit 0
}

foreach ($service in $servicesToUpdate) {
  $reason = "missing tasks on ready workers: $($service.MissingWorkers)"
  if ($PSCmdlet.ShouldProcess($service.Name, "docker service update --force ($reason)")) {
    Invoke-SshCommand `
      -Target $reachableManager.Target `
      -TimeoutSeconds $ConnectTimeoutSeconds `
      -Command "docker service update --force '$($service.Name)'" | Out-Null
    Write-Host "Triggered rolling rebalance for $($service.Name) via $($reachableManager.Name): $reason"
  }
}
