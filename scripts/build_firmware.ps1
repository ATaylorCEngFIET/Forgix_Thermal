param(
  [string]$PicoSdkPath = $env:PICO_SDK_PATH,
  [string]$ToolchainPath = $env:PICO_TOOLCHAIN_PATH,
  [string]$NinjaPath,
  [string]$PicotoolPath,
  [string]$BuildDir,
  [ValidateSet("waveshare_1in8", "adafruit_round_1in28")]
  [string]$Variant = "waveshare_1in8"
)

$ErrorActionPreference = "Stop"
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

if (-not $PicoSdkPath) {
  $PicoSdkPath = Join-Path $env:USERPROFILE ".pico-sdk\sdk\2.2.0"
}
if (-not (Test-Path (Join-Path $PicoSdkPath "external\pico_sdk_import.cmake"))) {
  throw "Pico SDK not found. Pass -PicoSdkPath or set PICO_SDK_PATH."
}
if (-not $ToolchainPath) {
  $ToolchainPath = Join-Path $env:USERPROFILE ".pico-sdk\toolchain\14_2_Rel1"
}
if (-not $NinjaPath) {
  $NinjaPath = Join-Path $env:USERPROFILE ".pico-sdk\ninja\v1.12.1\ninja.exe"
}
if (-not $PicotoolPath) {
  $PicotoolPath = Join-Path $env:USERPROFILE ".pico-sdk\picotool\2.2.0-a4"
}
if (-not (Test-Path (Join-Path $ToolchainPath "bin\arm-none-eabi-gcc.exe"))) {
  throw "Pico ARM toolchain not found. Pass -ToolchainPath."
}
if (-not (Test-Path $NinjaPath)) {
  throw "Ninja not found. Pass -NinjaPath."
}

Push-Location $projectRoot
try {
  if (-not $BuildDir) {
    $BuildDir = "firmware/build_$Variant"
  }
  if ($Variant -eq "adafruit_round_1in28") {
    $firmwareTarget = "forgix_lepton_adafruit_round_1in28"
    $fpgaImage = Join-Path $projectRoot "fpga\outflow\forgix_lepton_round.bin"
  }
  else {
    $firmwareTarget = "forgix_lepton_waveshare_1in8"
    $fpgaImage = Join-Path $projectRoot "fpga\outflow\forgix_lepton.bin"
  }
  $arguments = @(
    "-S", "firmware",
    "-B", $BuildDir,
    "-G", "Ninja",
    "-DPICO_SDK_PATH=$PicoSdkPath",
    "-DPICO_BOARD=pico2",
    "-DPICO_TOOLCHAIN_PATH=$ToolchainPath",
    "-DCMAKE_MAKE_PROGRAM=$NinjaPath",
    "-DPICOTOOL_FETCH_FROM_GIT_PATH=$PicotoolPath",
    "-DDISPLAY_VARIANT=$Variant",
    "-DFPGA_IMAGE=$fpgaImage"
  )
  & cmake @arguments
  if ($LASTEXITCODE -ne 0) {
    throw "CMake configuration failed with exit code $LASTEXITCODE"
  }
  & cmake --build $BuildDir
  if ($LASTEXITCODE -ne 0) {
    throw "Firmware build failed with exit code $LASTEXITCODE"
  }
  $distDir = Join-Path $projectRoot "dist"
  New-Item -ItemType Directory -Force -Path $distDir | Out-Null
  Copy-Item -LiteralPath (Join-Path $BuildDir "$firmwareTarget.uf2") `
    -Destination (Join-Path $distDir "$firmwareTarget.uf2") -Force
  Write-Host "Generated dist\$firmwareTarget.uf2"
}
finally {
  Pop-Location
}
