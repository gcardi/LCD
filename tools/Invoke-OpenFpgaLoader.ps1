# openFPGALoader is the default programming path on this project since
# 10 September 2026, when it produced the first flash boot with the fonts on
# board after programmer_cli had never managed one. Two things to know:
#
#   - it needs the WinUSB driver on interface 0 of the FT2232 (Zadig; see
#     docs/PROGRAMMING.md). While that driver is installed programmer_cli
#     cannot open the cable at all, so the two tools are mutually exclusive;
#   - its "CRC check: Success" covers the bitstream only. --verify applies to
#     external SPI flashes, and nobody reads the internal User Flash back. The
#     fonts are accertained at runtime instead, by the CRC-32 in FontStore.
#
# Unlike programmer_cli it reports failure honestly through the exit code, so
# there is no output sniffing here.
function Invoke-OpenFpgaLoader {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$LoaderPath
    )
    if (-not $LoaderPath) {
        $found = Get-Command 'openFPGALoader.exe' -ErrorAction SilentlyContinue
        $LoaderPath = if ($found) { $found.Source } else { 'C:\oss-cad-suite\bin\openFPGALoader.exe' }
    }
    if (-not (Test-Path -LiteralPath $LoaderPath -PathType Leaf)) {
        throw "openFPGALoader non trovato: $LoaderPath"
    }

    & $LoaderPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "openFPGALoader fallito con codice $LASTEXITCODE"
    }
}
