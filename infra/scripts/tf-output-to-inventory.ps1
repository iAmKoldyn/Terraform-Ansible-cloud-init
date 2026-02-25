param(
  [string]$TerraformDir = "../terraform",
  [string]$OutputFile = "../ansible/inventory/hosts.ini",
  [string]$AnsibleUser = "naurlox"
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

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not [System.IO.Path]::IsPathRooted($TerraformDir)) {
  $TerraformDir = Join-Path $scriptDir $TerraformDir
}
if (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
  $OutputFile = Join-Path $scriptDir $OutputFile
}

$terraformPath = (Resolve-Path $TerraformDir).Path
$outputDir = Split-Path -Parent $OutputFile
if (-not (Test-Path -LiteralPath $outputDir)) {
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$json = terraform -chdir="$terraformPath" output -json nodes
if ($LASTEXITCODE -ne 0) {
  throw "terraform output failed"
}

$nodes = $json | ConvertFrom-Json

$managers = @()
$workers = @()
$lbs = @()

foreach ($node in $nodes.PSObject.Properties) {
  $name = $node.Name
  $data = $node.Value
  $line = "$name ansible_host=$($data.ip)"

  switch ($data.role) {
    "manager" { $managers += $line }
    "worker"  { $workers += $line }
    "lb"      { $lbs += $line }
  }
}

$lines = @()
$lines += "[managers]"
$lines += ($managers | Sort-Object)
$lines += ""
$lines += "[workers]"
$lines += ($workers | Sort-Object)
$lines += ""
$lines += "[lbs]"
$lines += ($lbs | Sort-Object)
$lines += ""
$lines += "[all:vars]"
$lines += "ansible_user=$AnsibleUser"
$lines += "ansible_python_interpreter=/usr/bin/python3"

Write-Utf8NoBom -Path $OutputFile -Content ($lines -join "`n")
Write-Host "Inventory generated: $OutputFile"
