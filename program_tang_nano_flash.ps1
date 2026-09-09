param(
    [string]$Bitstream = (Join-Path $PSScriptRoot 'impl\pnr\LCD.fs'),
    [string]$UserFlash = (Join-Path $PSScriptRoot 'fonts\user_flash_fonts.fi'),
    [string]$ProgrammerPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tools\Invoke-GowinProgrammer.ps1')

foreach ($file in @($Bitstream, $UserFlash)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "File non trovato: $file" }
}
$resolvedBitstream = (Resolve-Path -LiteralPath $Bitstream).Path
$resolvedUserFlash = (Resolve-Path -LiteralPath $UserFlash).Path

Write-Host 'Programmazione e verifica della Embedded Flash e della User Flash...'
Write-Host "Bitstream:  $resolvedBitstream"
Write-Host "User Flash: $resolvedUserFlash"

# I font vanno sempre passati insieme al bitstream: Embedded Flash e User Flash
# sono lo stesso array, quindi programmare senza --fiFile li cancella.
Invoke-GowinProgrammer -ProgrammerPath $ProgrammerPath -Arguments @(
    '--device', 'GW1NR-9C',
    '--operation_index', '6',
    '--cable-index', '1',
    '--fsFile', $resolvedBitstream,
    '--fiFile', $resolvedUserFlash
) | Out-Null

Write-Host 'Embedded Flash e User Flash programmate e verificate.'
