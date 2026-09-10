param(
    [string]$Bitstream = (Join-Path $PSScriptRoot "impl\pnr\LCD.fs"),
    [string]$ProgrammerPath,
    # Torna a programmer_cli. Richiede che il driver FTDI sia quello originale:
    # con WinUSB installato da Zadig, programmer_cli non vede il cavo.
    [switch]$UseGowinProgrammer
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Bitstream -PathType Leaf)) {
    throw "File non trovato: $Bitstream"
}
$resolvedBitstream = (Resolve-Path -LiteralPath $Bitstream).Path

Write-Host "Programmazione SRAM della Tang Nano 9K..."
Write-Host "Bitstream: $resolvedBitstream"

# La sola SRAM di configurazione: la User Flash con i font resta intatta.
if ($UseGowinProgrammer) {
    . (Join-Path $PSScriptRoot 'tools\Invoke-GowinProgrammer.ps1')
    Invoke-GowinProgrammer -ProgrammerPath $ProgrammerPath -Arguments @(
        '--device', 'GW1NR-9C',
        '--operation_index', '2',
        '--cable-index', '1',
        '--fsFile', $resolvedBitstream
    ) | Out-Null
} else {
    . (Join-Path $PSScriptRoot 'tools\Invoke-OpenFpgaLoader.ps1')
    # Senza --write-flash openFPGALoader carica in SRAM.
    Invoke-OpenFpgaLoader -LoaderPath $ProgrammerPath -Arguments @(
        '-b', 'tangnano9k',
        $resolvedBitstream
    )
}

Write-Host "Programmazione SRAM completata."
exit 0
