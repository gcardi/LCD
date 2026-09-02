param(
    [string]$Bitstream = (Join-Path $PSScriptRoot "impl\pnr\Tang_nano_9K_LCD.fs")
)

$programmer = "C:\Program Files\Gowin\Gowin_V1.9.12.01_x64\IDE\bin\Gowin_V1.9.12.01_x64\Programmer\bin\programmer_cli.exe"

if (-not (Test-Path -LiteralPath $programmer -PathType Leaf)) {
    throw "Gowin Programmer CLI non trovato: $programmer"
}

$resolvedBitstream = (Resolve-Path -LiteralPath $Bitstream).Path

Write-Host "Programmazione SRAM della Tang Nano 9K..."
Write-Host "Bitstream: $resolvedBitstream"

& $programmer `
    --device GW1NR-9C `
    --operation_index 2 `
    --cable-index 1 `
    --fsFile $resolvedBitstream

if ($LASTEXITCODE -ne 0) {
    throw "Programmazione Gowin fallita con codice $LASTEXITCODE"
}

Write-Host "Programmazione SRAM completata."
