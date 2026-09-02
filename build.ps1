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
    [switch]$Program
)

$ErrorActionPreference = "Stop"
$root    = $PSScriptRoot
$project = Join-Path $root "LCD.gprj"

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

$tcl = Join-Path ([System.IO.Path]::GetTempPath()) "lcd_build_$PID.tcl"
@"
# Le graffe impediscono a Tcl di interpretare i backslash del percorso.
open_project {$project}
set_option -gen_text_timing_rpt 1
run all
"@ | Set-Content -LiteralPath $tcl -Encoding ascii

try {
    & $gwsh.Path $tcl 2>&1 | Tee-Object -Variable log | Where-Object {
        $_ -match "^(ERROR|WARN)" -or $_ -match "Bitstream generation completed"
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "--- ultime righe del log ---"
        $log | Select-Object -Last 15 | ForEach-Object { Write-Host "  $_" }
        throw "gw_sh ha restituito $LASTEXITCODE"
    }
} finally {
    Remove-Item -LiteralPath $tcl -ErrorAction SilentlyContinue
}

$bitstream = Join-Path $root "impl\pnr\LCD.fs"
if (-not (Test-Path -LiteralPath $bitstream -PathType Leaf)) {
    throw "Build terminata ma il bitstream non c'e': $bitstream"
}

# Il riepilogo di timing e' la parte che vale la pena leggere a ogni build.
$report = Join-Path $root "impl\pnr\LCD.tr"
if (Test-Path -LiteralPath $report -PathType Leaf) {
    $tr = Get-Content -LiteralPath $report

    Write-Host ""
    Write-Host "--- Timing ---"
    $tr | Select-String -Pattern "Violated Endpoints" | ForEach-Object { Write-Host "  $($_.Line.Trim())" }

    $fmaxAt = ($tr | Select-String -Pattern "^2\.3 Max Frequency Summary" | Select-Object -Last 1).LineNumber
    if ($fmaxAt) {
        $tr[$fmaxAt..($fmaxAt + 6)] | Where-Object { $_ -match "\(MHz\)" } |
            ForEach-Object { Write-Host "  $($_.Trim())" }
    }

    # Le violazioni note stanno tutte dentro l'IP PSRAM di Gowin: vedi le note
    # in src\LCD.sdc. Qualunque cosa fuori da psram_inst e' nostra, e nuova.
    $setupAt = ($tr | Select-String -Pattern "^3\.1\.1 Setup Paths Table" | Select-Object -Last 1).LineNumber
    if ($setupAt) {
        $ours = $tr[$setupAt..($setupAt + 30)] |
            Where-Object { $_ -match "^\s+\d+\s+-\d" -and $_ -notmatch "psram_inst" }
        if ($ours) {
            Write-Host ""
            Write-Warning "Violazioni di setup fuori dall'IP PSRAM:"
            $ours | ForEach-Object { Write-Host "  $($_.Trim())" }
        } else {
            Write-Host "  (violazioni residue: solo l'IP PSRAM, come da baseline)"
        }
    }
}

Write-Host ""
Write-Host "Bitstream: $bitstream"

if ($Program) {
    Write-Host ""
    & (Join-Path $root "program_tang_nano_sram.ps1")
}
