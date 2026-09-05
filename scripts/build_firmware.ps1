param(
  [string]$PicoSdkPath = $env:PICO_SDK_PATH,
  [string]$ToolchainPath = $env:PICO_TOOLCHAIN_PATH,
  [string]$NinjaPath,
  [string]$PicotoolPath,
  [string]$BuildDir = "lepton_thermal/firmware/build"
)

$ErrorActionPreference = "Stop"
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

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
  $arguments = @(
    "-S", "lepton_thermal/firmware",
    "-B", $BuildDir,
    "-G", "Ninja",
    "-DPICO_SDK_PATH=$PicoSdkPath",
    "-DPICO_BOARD=pico2",
    "-DPICO_TOOLCHAIN_PATH=$ToolchainPath",
    "-DCMAKE_MAKE_PROGRAM=$NinjaPath",
    "-DPICOTOOL_FETCH_FROM_GIT_PATH=$PicotoolPath"
  )
  & cmake @arguments
  if ($LASTEXITCODE -ne 0) {
    throw "CMake configuration failed with exit code $LASTEXITCODE"
  }
  & cmake --build $BuildDir
  if ($LASTEXITCODE -ne 0) {
    throw "Firmware build failed with exit code $LASTEXITCODE"
  }
}
finally {
  Pop-Location
}
