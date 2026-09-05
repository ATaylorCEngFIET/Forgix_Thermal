$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$work = Join-Path $root "sim\work"
New-Item -ItemType Directory -Force -Path $work | Out-Null

Push-Location $work
try {
  vlib work
  vcom -2008 (Join-Path $root "rtl\lepton_pkg.vhd")
  vcom -2008 (Join-Path $root "rtl\byte_fifo.vhd")
  vcom -2008 (Join-Path $root "rtl\uart_tx.vhd")
  vcom -2008 (Join-Path $root "rtl\lepton_vospi_capture.vhd")
  vcom -2008 (Join-Path $root "rtl\lepton_stream_formatter.vhd")
  vcom -2008 (Join-Path $root "rtl\forgix_lepton_top.vhd")
  vcom -2008 (Join-Path $root "sim\tb_byte_fifo.vhd")
  vcom -2008 (Join-Path $root "sim\tb_uart_tx.vhd")
  vcom -2008 (Join-Path $root "sim\tb_lepton_capture.vhd")
  vcom -2008 (Join-Path $root "sim\tb_stream_formatter.vhd")
  vcom -2008 (Join-Path $root "sim\tb_capture_stream.vhd")

  $fifoOutput = & vsim -c -do "run -all; quit -f" work.tb_byte_fifo 2>&1
  $fifoExit = $LASTEXITCODE
  $fifoOutput | ForEach-Object { Write-Host $_ }
  if ($fifoExit -ne 0 -or (($fifoOutput -join "`n") -match '\*\* (Failure|Fatal|Error):')) {
    throw "Byte FIFO simulation reported a failure (exit code $fifoExit)"
  }
  $uartOutput = & vsim -c -do "run -all; quit -f" work.tb_uart_tx 2>&1
  $uartExit = $LASTEXITCODE
  $uartOutput | ForEach-Object { Write-Host $_ }
  if ($uartExit -ne 0 -or (($uartOutput -join "`n") -match '\*\* (Failure|Fatal|Error):')) {
    throw "UART simulation reported a failure (exit code $uartExit)"
  }
  $captureOutput = & vsim -c -do "run -all; quit -f" work.tb_lepton_capture 2>&1
  $captureExit = $LASTEXITCODE
  $captureOutput | ForEach-Object { Write-Host $_ }
  if ($captureExit -ne 0 -or (($captureOutput -join "`n") -match '\*\* (Failure|Fatal|Error):')) {
    throw "VoSPI capture simulation reported a failure (exit code $captureExit)"
  }
  $formatterOutput = & vsim -c -do "run -all; quit -f" work.tb_stream_formatter 2>&1
  $formatterExit = $LASTEXITCODE
  $formatterOutput | ForEach-Object { Write-Host $_ }
  if ($formatterExit -ne 0 -or (($formatterOutput -join "`n") -match '\*\* (Failure|Fatal|Error):')) {
    throw "Stream formatter simulation reported a failure (exit code $formatterExit)"
  }
  $integratedOutput = & vsim -c -do "run -all; quit -f" work.tb_capture_stream 2>&1
  $integratedExit = $LASTEXITCODE
  $integratedOutput | ForEach-Object { Write-Host $_ }
  if ($integratedExit -ne 0 -or (($integratedOutput -join "`n") -match '\*\* (Failure|Fatal|Error):')) {
    throw "Integrated capture/stream simulation reported a failure (exit code $integratedExit)"
  }
}
finally {
  Pop-Location
}
