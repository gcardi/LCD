param(
    [string]$Bitstream = (Join-Path $PSScriptRoot 'impl\pnr\LCD.fs'),
    # Nota il formato: openFPGALoader vuole l'immagine binaria grezza, mentre
    # programmer_cli vuole il .fi di Gowin. Passare il file sbagliato non da'
    # errore, scrive font non validi. Vedi docs/PROGRAMMING.md.
    [string]$UserFlash,
    [string]$ProgrammerPath,
    [switch]$UseGowinProgrammer
)

$ErrorActionPreference = 'Stop'

if (-not $UserFlash) {
    $UserFlash = Join-Path $PSScriptRoot (
        if ($UseGowinProgrammer) { 'fonts\user_flash_fonts.fi' }
        else { 'fonts\user_flash_fonts.bin' })
}

foreach ($file in @($Bitstream, $UserFlash)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "File non trovato: $file" }
}
$resolvedBitstream = (Resolve-Path -LiteralPath $Bitstream).Path
$resolvedUserFlash = (Resolve-Path -LiteralPath $UserFlash).Path

Write-Host 'Programmazione della Embedded Flash e della User Flash...'
Write-Host "Bitstream:  $resolvedBitstream"
Write-Host "User Flash: $resolvedUserFlash"

# I font vanno sempre passati insieme al bitstream: Embedded Flash e User Flash
# sono lo stesso array, quindi programmare senza i font li cancella.
if ($UseGowinProgrammer) {
    . (Join-Path $PSScriptRoot 'tools\Invoke-GowinProgrammer.ps1')
    $result = Invoke-GowinProgrammer -ProgrammerPath $ProgrammerPath -Arguments @(
        '--device', 'GW1NR-9C',
        '--operation_index', '6',
        '--cable-index', '1',
        '--fsFile', $resolvedBitstream,
        '--fiFile', $resolvedUserFlash
    )
    if ($result.VerifyWarning) {
        # Mai dichiarare verificato cio' che il tool ha rifiutato di verificare.
        Write-Host 'Embedded Flash e User Flash programmate; verifica NON superata.'
        Write-Host 'Conferma con un ciclo di alimentazione, come indicato sopra.'
    } else {
        Write-Host 'Embedded Flash e User Flash programmate e verificate.'
    }
} else {
    . (Join-Path $PSScriptRoot 'tools\Invoke-OpenFpgaLoader.ps1')
    Invoke-OpenFpgaLoader -LoaderPath $ProgrammerPath -Arguments @(
        '-b', 'tangnano9k',
        '--write-flash', $resolvedBitstream,
        '--user-flash', $resolvedUserFlash
    )
    # "CRC check: Success" riguarda solo il bitstream: la User Flash non viene
    # riletta da nessuno, e l'unica prova che i font siano buoni e' il CRC-32
    # che FontStore calcola a runtime.
    Write-Host 'Embedded Flash e User Flash programmate.'
    Write-Host 'I font si accertano a runtime: resetta la MCU e guarda il testo.'
    Write-Host 'Se g_lcd_error.phase vale 11, l''immagine font non e'' valida.'
}
exit 0
