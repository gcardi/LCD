<#
.SYNOPSIS
    Esegue il testbench di risincronizzazione del frame con Icarus Verilog.

.DESCRIPTION
    Inietta un underrun della FIFO a meta' area visibile e conta quanti frame
    restano danneggiati dopo il guasto. Il modello di PSRAM ignora i dati
    scritti e risponde con un pattern derivato dall'indirizzo: le barre
    orizzontali non possono rivelare un disallineamento, una rampa per-pixel
    si'.

.PARAMETER Mode
    current : RTL attuale con FramebufferFifo (default)
    model   : RTL attuale con la FIFO comportamentale di riferimento
    legacy  : RTL precedente alla risincronizzazione, estratto da git.
              Dimostra il bug: danno permanente su ogni frame successivo.

.EXAMPLE
    .\sim\run_sim.ps1
    .\sim\run_sim.ps1 -Mode legacy
#>
param(
    [ValidateSet("current", "model", "legacy")]
    [string]$Mode = "current",

    # Ultimo commit prima dell'introduzione della risincronizzazione.
    [string]$LegacyRev = "1e9337d",

    [string]$OssCadSuite = "C:\oss-cad-suite"
)

$ErrorActionPreference = "Stop"
$root  = Split-Path -Parent $PSScriptRoot
$sim   = Join-Path $root "sim"
$build = Join-Path $sim "build"

if (-not (Test-Path -LiteralPath $OssCadSuite -PathType Container)) {
    throw "oss-cad-suite non trovato: $OssCadSuite (usa -OssCadSuite per indicarlo)"
}

# iverilog e vvp non partono senza queste due variabili.
$env:YOSYSHQ_ROOT = "$OssCadSuite\"
$env:PATH = "$OssCadSuite\bin;$OssCadSuite\lib;$env:PATH"

New-Item -ItemType Directory -Force $build | Out-Null

$defines = @()
$sources = @(
    (Join-Path $sim "tb_frame_resync.sv"),
    (Join-Path $sim "models.sv"),
    (Join-Path $root "src\ResetSynchronizer.sv"),
    (Join-Path $root "src\PulseSynchronizer.sv")
)

switch ($Mode) {
    "current" {
        $defines += "-DREAL_FIFO"
        $sources += (Join-Path $root "src\VGA_Timing.sv")
        $sources += (Join-Path $root "src\FramebufferController.sv")
        $sources += (Join-Path $root "src\FramebufferFifo.sv")
    }
    "model" {
        $sources += (Join-Path $root "src\VGA_Timing.sv")
        $sources += (Join-Path $root "src\FramebufferController.sv")
    }
    "legacy" {
        # Le sorgenti pre-fix non sono versionate qui: si rigenerano da git,
        # cosi' non esistono due copie divergenti dello stesso file.
        $legacy = Join-Path $sim "legacy"
        New-Item -ItemType Directory -Force $legacy | Out-Null
        foreach ($f in @("VGA_Timing.sv", "FramebufferController.sv")) {
            $out = Join-Path $legacy $f
            & git -C $root show "${LegacyRev}:src/$f" | Set-Content -LiteralPath $out -Encoding utf8
            if ($LASTEXITCODE -ne 0) { throw "git show fallito per $f a $LegacyRev" }
        }
        Write-Host "Sorgenti pre-fix estratte da $LegacyRev"
        $defines += "-DLEGACY"
        $sources += (Join-Path $legacy "VGA_Timing.sv")
        $sources += (Join-Path $legacy "FramebufferController.sv")
    }
}

$vvp = Join-Path $build "tb_$Mode.vvp"

Write-Host "Compilazione ($Mode)..."
# I 'sorry:' di Icarus sui select costanti rendono i processi piu' sensibili,
# non meno: innocui qui.
& iverilog -g2012 @defines -o $vvp @sources 2>&1 |
    Where-Object { $_ -notmatch "sorry: constant selects" }
if (-not (Test-Path -LiteralPath $vvp)) { throw "compilazione fallita" }

Write-Host "Simulazione (circa un minuto)..."
& vvp $vvp
if ($LASTEXITCODE -ne 0) { throw "simulazione fallita con codice $LASTEXITCODE" }
