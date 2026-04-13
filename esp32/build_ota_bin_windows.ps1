param(
    [string]$ArduinoCli = "arduino-cli",
    [string]$Fqbn = "esp32:esp32:esp32s3",
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sketchDir = Join-Path $scriptDir "motor_controller"
$sketchFile = Join-Path $sketchDir "motor_controller.ino"

if (-not (Test-Path $sketchFile)) {
    throw "Could not find sketch at $sketchFile"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $scriptDir "build\esp32-ota"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$compileArgs = @(
    "compile",
    "--fqbn", $Fqbn,
    "--output-dir", $OutputDir,
    $sketchDir
)

Write-Host ""
Write-Host "Compiling SmartCane ESP32 firmware..."
Write-Host "  Arduino CLI: $ArduinoCli"
Write-Host "  FQBN:        $Fqbn"
Write-Host "  Sketch:      $sketchDir"
Write-Host "  Output:      $OutputDir"
Write-Host ""

& $ArduinoCli @compileArgs

$appBin = Join-Path $OutputDir "motor_controller.ino.bin"
$otaBin = Join-Path $OutputDir "smartcane_esp32_ota.bin"

if (-not (Test-Path $appBin)) {
    throw "Compile finished but $appBin was not found."
}

Copy-Item -Force $appBin $otaBin

Write-Host ""
Write-Host "Done."
Write-Host "OTA firmware image:"
Write-Host "  $otaBin"
Write-Host ""
Write-Host "Upload it at:"
Write-Host "  http://192.168.4.1/update"
