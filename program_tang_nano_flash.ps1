param(
    [string]$Bitstream = (Join-Path $PSScriptRoot 'impl\pnr\LCD.fs'),
    # Sempre l'immagine binaria: e' l'unico artefatto dei font versionato.
    # Il .fi che programmer_cli pretende viene trascritto da qui al volo.
    [string]$UserFlash = (Join-Path $PSScriptRoot 'fonts\user_flash_fonts.bin'),
    [string]$ProgrammerPath,
    # Torna a programmer_cli. Richiede il driver FTDI originale: con il WinUSB
    # installato da Zadig, programmer_cli non vede il cavo e resta appeso.
    [switch]$UseGowinProgrammer
)

$ErrorActionPreference = 'Stop'

foreach ($file in @($Bitstream, $UserFlash)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "File non trovato: $file" }
}
$resolvedBitstream = (Resolve-Path -LiteralPath $Bitstream).Path
$resolvedUserFlash = (Resolve-Path -LiteralPath $UserFlash).Path

# Lo stesso controllo che FontStore fa a bordo, ma prima di scrivere invece che
# dopo. Nessuno dei due programmatori si accorge di ricevere il formato
# sbagliato: scrivono e basta, e il guasto si manifesta solo come font non
# validi. Vedi docs/PROGRAMMING.md.
$magic = [byte[]](Get-Content -LiteralPath $resolvedUserFlash -AsByteStream -TotalCount 4)
if ([System.Text.Encoding]::ASCII.GetString($magic) -ne 'LCDF') {
    throw @(
        "L'immagine font non comincia per LCDF: $resolvedUserFlash",
        "Serve l'immagine binaria grezza, non il .fi ne' il .mem.",
        "Rigenerala con tools/generate_user_flash_fonts.py."
    ) -join "`n"
}

Write-Host 'Programmazione della Embedded Flash e della User Flash...'
Write-Host "Bitstream:  $resolvedBitstream"
Write-Host "User Flash: $resolvedUserFlash"

# I font vanno sempre passati insieme al bitstream: Embedded Flash e User Flash
# sono lo stesso array, quindi programmare senza i font li cancella.
if ($UseGowinProgrammer) {
    . (Join-Path $PSScriptRoot 'tools\Invoke-GowinProgrammer.ps1')

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw 'python non trovato: serve per trascrivere il .fi.' }
    $fiFile = Join-Path ([IO.Path]::GetTempPath()) "user_flash_fonts_$PID.fi"
    try {
        & $python.Source (Join-Path $PSScriptRoot 'tools\generate_user_flash_fonts.py') `
            --fi-from $resolvedUserFlash --fi-out $fiFile | Write-Host
        if ($LASTEXITCODE -ne 0) { throw 'Trascrizione del .fi fallita.' }

        $result = Invoke-GowinProgrammer -ProgrammerPath $ProgrammerPath -Arguments @(
            '--device', 'GW1NR-9C',
            '--operation_index', '6',
            '--cable-index', '1',
            '--fsFile', $resolvedBitstream,
            '--fiFile', $fiFile
        )
    } finally {
        Remove-Item -LiteralPath $fiFile -ErrorAction SilentlyContinue
    }

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
