param(
    [string]$Bitstream = (Join-Path $PSScriptRoot "impl\pnr\LCD.fs"),
    [string]$ProgrammerPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'tools\Invoke-GowinProgrammer.ps1')

if (-not (Test-Path -LiteralPath $Bitstream -PathType Leaf)) {
    throw "File non trovato: $Bitstream"
}
$resolvedBitstream = (Resolve-Path -LiteralPath $Bitstream).Path

Write-Host "Programmazione SRAM della Tang Nano 9K..."
Write-Host "Bitstream: $resolvedBitstream"

# La sola SRAM di configurazione: la User Flash con i font resta intatta.
Invoke-GowinProgrammer -ProgrammerPath $ProgrammerPath -Arguments @(
    '--device', 'GW1NR-9C',
    '--operation_index', '2',
    '--cable-index', '1',
    '--fsFile', $resolvedBitstream
) | Out-Null

Write-Host "Programmazione SRAM completata."
exit 0
