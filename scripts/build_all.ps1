param(
  [string]$EfinityRoot = "C:\Efinity\2025.2"
)

$ErrorActionPreference = "Stop"
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

Push-Location $projectRoot
try {
  & .\lepton_thermal\fpga\scripts\build_efinity.ps1 -EfinityRoot $EfinityRoot
  if ($LASTEXITCODE -ne 0) {
    throw "FPGA build failed with exit code $LASTEXITCODE"
  }
  & .\lepton_thermal\scripts\build_firmware.ps1
  if ($LASTEXITCODE -ne 0) {
    throw "Firmware build failed with exit code $LASTEXITCODE"
  }
}
finally {
  Pop-Location
}
