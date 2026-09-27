param(
  [string]$EfinityRoot = "C:\Efinity\2025.2"
)

$ErrorActionPreference = "Stop"
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

Push-Location $projectRoot
try {
  foreach ($variant in @("waveshare_1in8", "adafruit_round_1in28")) {
    & .\fpga\scripts\build_efinity.ps1 -EfinityRoot $EfinityRoot -Variant $variant
    if ($LASTEXITCODE -ne 0) {
      throw "FPGA build failed for $variant with exit code $LASTEXITCODE"
    }
    & .\scripts\build_firmware.ps1 -Variant $variant
    if ($LASTEXITCODE -ne 0) {
      throw "Firmware build failed for $variant with exit code $LASTEXITCODE"
    }
  }
}
finally {
  Pop-Location
}
