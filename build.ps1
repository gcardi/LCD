<#
.SYNOPSIS
    Sintesi e place-and-route del progetto con Gowin EDA, senza aprire la GUI.

.DESCRIPTION
    Produce impl\pnr\LCD.fs e stampa il riepilogo di timing. L'installazione di
    Gowin viene cercata, non cablata: se ne hai piu' di una viene usata la piu'
    recente, oppure indicane una con -GowinRoot.

.PARAMETER Program
    Al termine carica il bitstream nella SRAM chiamando
    program_tang_nano_sram.ps1.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Program
#>
param(
    [string]$GowinRoot = "C:\Program Files\Gowin",
    [switch]$Program,
    # Il bitstream compresso non supera la verifica della Embedded Flash:
    # -NoCompress lo disattiva quando si vuole programmare e verificare.
    [switch]$NoCompress,
    # Sforzo del placer Gowin. Il default 1 e' quello qualificato; valori diversi
    # spostano il piazzamento e servono a valutare percorsi al limite.
    [ValidateRange(0,2)][int]$PlaceOption = 1
)

$ErrorActionPreference = "Stop"
$root    = $PSScriptRoot
$project = Join-Path $root "LCD.gprj"
. (Join-Path $root 'tools\Invoke-LoggedProcess.ps1')

if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
    throw "Progetto non trovato: $project"
}

# La gerarchia dell'installer annida il percorso (IDE\bin\Gowin_...\IDE\bin),
# quindi si cerca l'eseguibile invece di ricostruirlo a mano.
$found = Get-ChildItem -LiteralPath $GowinRoot -Filter "gw_sh.exe" -Recurse -File -ErrorAction SilentlyContinue
if (-not $found) {
    throw "gw_sh.exe non trovato sotto $GowinRoot (usa -GowinRoot per indicarlo)"
}

# Ordinare i percorsi come stringhe metterebbe 1.9.9 davanti a 1.9.12: la
# versione va estratta e confrontata come tale.
$gwsh = $found | ForEach-Object {
    $ver = [version]"0.0"
    if ($_.FullName -match 'Gowin_V(\d+(?:\.\d+)+)_x64') {
        try { $ver = [version]$Matches[1] } catch { }
    }
    [pscustomobject]@{ Path = $_.FullName; Version = $ver }
} | Sort-Object Version -Descending | Select-Object -First 1

Write-Host "Toolchain: $($gwsh.Path)"

$impl = Join-Path $root 'impl'
New-Item -ItemType Directory -Force $impl | Out-Null
$bitstream = Join-Path $root 'impl\pnr\LCD.fs'
$report = Join-Path $root 'impl\pnr\LCD.tr'
$manifest = Join-Path $impl 'verification.json'
# A failed build must never leave a previous bitstream/report looking current.
foreach ($old in @($bitstream, $report, $manifest)) {
    # Gowin marks .fs read-only after generation.
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
}

$tcl = Join-Path ([System.IO.Path]::GetTempPath()) "lcd_build_$PID.tcl"
@"
# Le graffe impediscono a Tcl di interpretare i backslash del percorso.
open_project {$project}
set_option -gen_text_timing_rpt 1
set_option -place_option $PlaceOption
set_option -route_option 1
set_option -bit_security 0
# Multi-Boot fa saltare il dispositivo a un secondo bitstream nella flash SPI
# esterna, che su questa scheda e' vergine: il salto fallisce e la FPGA resta
# non configurata all'accensione. Questo progetto non usa il multi-boot.
set_option -multi_boot 0
set_option -bit_compress $(if ($NoCompress) { 0 } else { 1 })
run all
"@ | Set-Content -LiteralPath $tcl -Encoding ascii

try {
    Invoke-LoggedProcess -FilePath $gwsh.Path -Arguments @($tcl) -LogPath (Join-Path $impl 'build.log') -TimeoutSeconds 900
} finally {
    Remove-Item -LiteralPath $tcl -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $bitstream -PathType Leaf)) {
    throw "Build terminata ma il bitstream non c'e': $bitstream"
}

# Missing/truncated reports and new violations are build failures, before -Program.
$timing = & (Join-Path $root 'tools\Test-TimingReport.ps1') -ReportPath $report
[ordered]@{
    VerifiedAtUtc = [DateTime]::UtcNow.ToString('o')
    Toolchain = $gwsh.Path
    BitstreamSHA256 = (Get-FileHash -LiteralPath $bitstream -Algorithm SHA256).Hash
    ReportSHA256 = (Get-FileHash -LiteralPath $report -Algorithm SHA256).Hash
    Timing = $timing
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding utf8

Write-Host ""
Write-Host "Bitstream: $bitstream"

if ($Program) {
    Write-Host ""
    & (Join-Path $root "program_tang_nano_sram.ps1")
}
