param(
  [string]$EfinityRoot = "C:\Efinity\2025.2"
)

$ErrorActionPreference = "Stop"
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$setupScript = Join-Path $EfinityRoot "bin\setup.bat"

if (-not (Test-Path -LiteralPath $setupScript)) {
  throw "Efinity setup script was not found at $setupScript"
}

Push-Location $projectRoot
try {
  $buildCommand = "call `"$setupScript`""
  $buildCommand += " && python scripts\create_periphery.py"
  $buildCommand += " && efx_run.bat --prj -f compile forgix_lepton"
  cmd /c $buildCommand
  if ($LASTEXITCODE -ne 0) {
    throw "Efinity build failed with exit code $LASTEXITCODE"
  }

  $hexPath = Join-Path $projectRoot "outflow\forgix_lepton.hex"
  if (-not (Test-Path -LiteralPath $hexPath)) {
    throw "Expected passive-SPI image was not generated: $hexPath"
  }

  $binPath = Join-Path $projectRoot "outflow\forgix_lepton.bin"
  python scripts\efinity_hex_to_bin.py $hexPath $binPath
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to convert the Efinity image"
  }

  Write-Host "Generated $binPath"
}
finally {
  Pop-Location
}
