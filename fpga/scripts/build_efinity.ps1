param(
  [string]$EfinityRoot = "C:\Efinity\2025.2",
  [ValidateSet("waveshare_1in8", "adafruit_round_1in28")]
  [string]$Variant = "waveshare_1in8"
)

$ErrorActionPreference = "Stop"
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$setupScript = Join-Path $EfinityRoot "bin\setup.bat"

if (-not (Test-Path -LiteralPath $setupScript)) {
  throw "Efinity setup script was not found at $setupScript"
}

Push-Location $projectRoot
try {
  if ($Variant -eq "adafruit_round_1in28") {
    $designName = "forgix_lepton_round"
    $baseProject = Get-Content -LiteralPath "forgix_lepton.xml" -Raw
    $variantProject = $baseProject.Replace(
      'name="forgix_lepton" description=',
      'name="forgix_lepton_round" description=').Replace(
      '<efx:top_module name="forgix_lepton" />',
      '<efx:top_module name="forgix_lepton_round" />').Replace(
      '<efx:design_file name="rtl/forgix_lepton_top.vhd" version="default" library="default" />',
      '<efx:design_file name="rtl/forgix_lepton_top.vhd" version="default" library="default" />' + "`r`n" +
      '    <efx:design_file name="rtl/forgix_lepton_round_top.vhd" version="default" library="default" />')
    [System.IO.File]::WriteAllText(
      (Join-Path $projectRoot "forgix_lepton_round.xml"),
      $variantProject,
      [System.Text.UTF8Encoding]::new($false))
  }
  else {
    $designName = "forgix_lepton"
  }

  $buildCommand = "call `"$setupScript`""
  $buildCommand += " && python scripts\create_periphery.py --design-name $designName"
  $buildCommand += " && efx_run.bat --prj -f compile $designName"
  cmd /c $buildCommand
  if ($LASTEXITCODE -ne 0) {
    throw "Efinity build failed with exit code $LASTEXITCODE"
  }

  $hexPath = Join-Path $projectRoot "outflow\$designName.hex"
  if (-not (Test-Path -LiteralPath $hexPath)) {
    throw "Expected passive-SPI image was not generated: $hexPath"
  }

  $binPath = Join-Path $projectRoot "outflow\$designName.bin"
  python scripts\efinity_hex_to_bin.py $hexPath $binPath
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to convert the Efinity image"
  }

  Write-Host "Generated $binPath"
}
finally {
  Pop-Location
}
