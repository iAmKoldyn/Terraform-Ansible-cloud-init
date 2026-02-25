param(
  [Parameter(Mandatory = $true)]
  [string]$TemplateName,

  [Parameter(Mandatory = $true)]
  [string]$VmName,

  [Parameter(Mandatory = $true)]
  [string]$HostOnlyAdapter,

  [Parameter(Mandatory = $true)]
  [int]$Cpus,

  [Parameter(Mandatory = $true)]
  [int]$MemoryMb,

  [Parameter(Mandatory = $true)]
  [string]$SeedIsoPath,

  [bool]$StartVm = $true
)

$ErrorActionPreference = "Stop"

function Invoke-VBox {
  param([string[]]$CommandArgs)
  & VBoxManage @CommandArgs
  if ($LASTEXITCODE -ne 0) {
    throw "VBoxManage failed: $($CommandArgs -join ' ')"
  }
}

function Invoke-VBoxIgnoreError {
  param([string[]]$CommandArgs)
  try {
    & VBoxManage @CommandArgs *> $null
  } catch {
    # Intentionally ignore errors for best-effort cleanup operations.
  }
}

function Test-VmExists {
  param([string]$Name)
  $vms = VBoxManage list vms
  return ($vms | Select-String -SimpleMatch "`"$Name`"") -ne $null
}

function Get-VmState {
  param([string]$Name)
  $info = VBoxManage showvminfo $Name --machinereadable
  $stateLine = $info | Where-Object { $_ -like "VMState=*" } | Select-Object -First 1
  if (-not $stateLine) { return "unknown" }
  return (($stateLine -split "=")[1]).Trim('"')
}

if (-not (Test-Path -LiteralPath $SeedIsoPath)) {
  throw "seed.iso not found at $SeedIsoPath"
}

if (-not (Test-VmExists -Name $VmName)) {
  Invoke-VBox -CommandArgs @("clonevm", $TemplateName, "--name", $VmName, "--register")
}

$state = Get-VmState -Name $VmName
if ($state -eq "running") {
  Invoke-VBoxIgnoreError -CommandArgs @("controlvm", $VmName, "poweroff")
  Start-Sleep -Seconds 3
}

Invoke-VBox -CommandArgs @("modifyvm", $VmName, "--cpus", "$Cpus", "--memory", "$MemoryMb")
Invoke-VBox -CommandArgs @("modifyvm", $VmName, "--nic1", "hostonly", "--hostonlyadapter1", $HostOnlyAdapter, "--cableconnected1", "on")
Invoke-VBox -CommandArgs @("modifyvm", $VmName, "--nic2", "nat", "--cableconnected2", "on")

Invoke-VBoxIgnoreError -CommandArgs @("modifyvm", $VmName, "--natpf2", "delete", "ssh")
Invoke-VBoxIgnoreError -CommandArgs @("storageattach", $VmName, "--storagectl", "IDE", "--port", "0", "--device", "1", "--type", "dvddrive", "--medium", "none")
Invoke-VBox -CommandArgs @("storageattach", $VmName, "--storagectl", "IDE", "--port", "0", "--device", "1", "--type", "dvddrive", "--medium", $SeedIsoPath)

if ($StartVm) {
  $state = Get-VmState -Name $VmName
  if ($state -ne "running") {
    Invoke-VBox -CommandArgs @("startvm", $VmName, "--type", "headless")
  }
}

Write-Host "VM ready: $VmName"
