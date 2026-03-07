param(
  [string]$Inventory = "../ansible/inventory/hosts.ini",
  [string]$KnownHostsFile = "",
  [int]$Port = 22,
  [int]$MaxAttempts = 60,
  [int]$DelaySeconds = 5,
  [int]$ConnectTimeoutSeconds = 5,
  [switch]$AutoResetUnreadyVm = $true
)

$ErrorActionPreference = "Stop"

function Get-InventoryHosts {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $hosts = @()
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed.StartsWith("[")) {
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

  return $hosts | Sort-Object -Property Address -Unique
}

function Ensure-KnownHostsFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType File -Path $Path -Force | Out-Null
  }
}

function Remove-KnownHostEntry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HostValue,

    [Parameter(Mandatory = $true)]
    [string]$KnownHostsPath
  )

  $escapedKnownHosts = $KnownHostsPath.Replace('"', '\"')
  $escapedHostValue = $HostValue.Replace('"', '\"')
  cmd.exe /c "ssh-keygen -f `"$escapedKnownHosts`" -R `"$escapedHostValue`" >NUL 2>NUL" | Out-Null
}

function Wait-ForSshPort {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Address,

    [Parameter(Mandatory = $true)]
    [int]$PortNumber,

    [Parameter(Mandatory = $true)]
    [int]$Attempts,

    [Parameter(Mandatory = $true)]
    [int]$SleepSeconds
  )

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $client = New-Object System.Net.Sockets.TcpClient
    $asyncResult = $null
    try {
      $asyncResult = $client.BeginConnect($Address, $PortNumber, $null, $null)
      if ($asyncResult.AsyncWaitHandle.WaitOne(2000) -and $client.Connected) {
        return $true
      }
    } catch {
    } finally {
      if ($asyncResult) {
        $asyncResult.AsyncWaitHandle.Close()
      }
      $client.Close()
    }

    Start-Sleep -Seconds $SleepSeconds
  }

  return $false
}

function Get-HostKeyLines {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Address,

    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds
  )

  $output = wsl bash -lc "ssh-keyscan -T $TimeoutSeconds '$Address' 2>/dev/null"
  if ($LASTEXITCODE -ne 0 -or -not $output) {
    throw "ssh-keyscan failed for $Address"
  }

  return @($output | Where-Object { $_ -and -not $_.StartsWith("#") })
}

function Get-HostKeyLinesWithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Address,

    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds,

    [Parameter(Mandatory = $true)]
    [int]$Attempts,

    [Parameter(Mandatory = $true)]
    [int]$SleepSeconds
  )

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      $keyLines = Get-HostKeyLines -Address $Address -TimeoutSeconds $TimeoutSeconds
      if ($keyLines.Count -gt 0) {
        return $keyLines
      }
    } catch {
    }

    Start-Sleep -Seconds $SleepSeconds
  }

  throw "ssh-keyscan failed for $Address"
}

function Test-VmExists {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $vms = VBoxManage list vms 2>$null
  return ($LASTEXITCODE -eq 0 -and ($vms | Select-String -SimpleMatch "`"$Name`"") -ne $null)
}

function Get-VmState {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $info = VBoxManage showvminfo $Name --machinereadable 2>$null
  if ($LASTEXITCODE -ne 0) {
    return "unknown"
  }

  $stateLine = $info | Where-Object { $_ -like "VMState=*" } | Select-Object -First 1
  if (-not $stateLine) {
    return "unknown"
  }

  return (($stateLine -split "=")[1]).Trim('"')
}

function Restart-VmForRecovery {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if (-not (Test-VmExists -Name $Name)) {
    return $false
  }

  $state = Get-VmState -Name $Name
  try {
    switch ($state) {
      "running" {
        VBoxManage controlvm $Name reset *> $null
      }
      "poweroff" {
        VBoxManage startvm $Name --type headless *> $null
      }
      default {
        VBoxManage controlvm $Name poweroff *> $null
        Start-Sleep -Seconds 3
        VBoxManage startvm $Name --type headless *> $null
      }
    }
  } catch {
    return $false
  }

  Start-Sleep -Seconds 10
  return $true
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not [System.IO.Path]::IsPathRooted($Inventory)) {
  $Inventory = Join-Path $scriptDir $Inventory
}

if ([string]::IsNullOrWhiteSpace($KnownHostsFile)) {
  $KnownHostsFile = Join-Path $env:USERPROFILE ".ssh\known_hosts"
}

$inventoryResolved = (Resolve-Path -LiteralPath $Inventory).Path
$knownHostsResolved = [System.IO.Path]::GetFullPath($KnownHostsFile)

Get-Command ssh-keygen -ErrorAction Stop | Out-Null
Get-Command ssh-keyscan -ErrorAction Stop | Out-Null

Ensure-KnownHostsFile -Path $knownHostsResolved
$hosts = Get-InventoryHosts -Path $inventoryResolved

if (-not $hosts) {
  Write-Host "No hosts found in inventory: $inventoryResolved"
  exit 0
}

foreach ($node in $hosts) {
  Remove-KnownHostEntry -HostValue $node.Address -KnownHostsPath $knownHostsResolved
  Remove-KnownHostEntry -HostValue $node.Name -KnownHostsPath $knownHostsResolved
}

$refreshed = @()
foreach ($node in $hosts) {
  $nodeReady = $false
  $recoveryAttempted = $false

  while (-not $nodeReady) {
    $portReady = Wait-ForSshPort -Address $node.Address -PortNumber $Port -Attempts $MaxAttempts -SleepSeconds $DelaySeconds
    if ($portReady) {
      try {
        $keyLines = Get-HostKeyLinesWithRetry -Address $node.Address -TimeoutSeconds $ConnectTimeoutSeconds -Attempts 24 -SleepSeconds $DelaySeconds
        Add-Content -LiteralPath $knownHostsResolved -Value ($keyLines -join [Environment]::NewLine)
        $refreshed += $node.Address
        $nodeReady = $true
        continue
      } catch {
      }
    }

    if ($AutoResetUnreadyVm -and -not $recoveryAttempted) {
      Write-Host "Recovering unready VM: $($node.Name) ($($node.Address))"
      if (Restart-VmForRecovery -Name $node.Name) {
        $recoveryAttempted = $true
        continue
      }
    }

    if (-not $portReady) {
      throw "SSH on $($node.Address):$Port did not become ready within $($MaxAttempts * $DelaySeconds) seconds"
    }

    throw "ssh-keyscan failed for $($node.Address)"
  }
}

Write-Host ("known_hosts refreshed for: " + ($refreshed -join ", "))
