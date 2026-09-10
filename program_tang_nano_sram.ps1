param(
    [string]$Bitstream = (Join-Path $PSScriptRoot "impl\pnr\LCD.fs"),
    [string]$ProgrammerPath,
    # Indice del tipo di cavo per programmer_cli: 1 e' FT2CH, 5 e' WINUSB.
    # Vedi docs/PROGRAMMING.md, che spiega quale serve con quale driver.
    [int]$CableIndex = 1,
    # Torna a programmer_cli invece di openFPGALoader.
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
        '--cable-index', "$CableIndex",
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
