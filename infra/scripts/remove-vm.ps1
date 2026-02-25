param(
  [Parameter(Mandatory = $true)]
  [string]$VmName
)

$ErrorActionPreference = "Stop"

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

if (-not (Test-VmExists -Name $VmName)) {
  Write-Host "VM does not exist: $VmName"
  exit 0
}

$state = Get-VmState -Name $VmName
if ($state -eq "running") {
  & VBoxManage controlvm $VmName poweroff | Out-Null
  Start-Sleep -Seconds 3
}

& VBoxManage unregistervm $VmName --delete
if ($LASTEXITCODE -ne 0) {
  throw "Failed to remove VM: $VmName"
}

Write-Host "VM deleted: $VmName"
