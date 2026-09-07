<#
.SYNOPSIS
    Regressione framebuffer: current, model, legacy oppure all.
.DESCRIPTION
    current/model devono recuperare al frame seguente; legacy deve riprodurre
    il danno persistente, dopo frame iniziali corretti. Log in sim/build.
    Servono oss-cad-suite e, solo per legacy/all, la cronologia Git.
#>
param(
    [ValidateSet('current', 'model', 'legacy', 'all')]
    [string]$Mode = 'current',
    [string]$LegacyRev = '1e9337d',
    [string]$OssCadSuite = 'C:\oss-cad-suite',
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $PSScriptRoot 'build'
. (Join-Path $root 'tools\Invoke-LoggedProcess.ps1')
$compiler = Join-Path $OssCadSuite 'bin\iverilog.exe'
$runtime = Join-Path $OssCadSuite 'bin\vvp.exe'
foreach ($exe in @($compiler, $runtime)) {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Tool non trovato: $exe" }
}
New-Item -ItemType Directory -Force $build | Out-Null
$savedPath = $env:PATH
$savedRoot = $env:YOSYSHQ_ROOT
try {
    $env:YOSYSHQ_ROOT = "$OssCadSuite\"
    $env:PATH = "$OssCadSuite\bin;$OssCadSuite\lib;$savedPath"
    $modes = if ($Mode -eq 'all') { @('current', 'model', 'legacy') } else { @($Mode) }
    foreach ($variant in $modes) {
        $vvp = Join-Path $build "tb_$variant.vvp"
        $compileLog = Join-Path $build "compile_$variant.log"
        $runLog = Join-Path $build "run_$variant.log"
        # Invalidate previous results before any operation that can fail.
        foreach ($old in @($vvp, $compileLog, $runLog)) {
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old }
        }
        $defines = @()
        $sources = @(
            (Join-Path $PSScriptRoot 'tb_frame_resync.sv'),
            (Join-Path $PSScriptRoot 'models.sv'),
            (Join-Path $root 'src\ResetSynchronizer.sv'),
            (Join-Path $root 'src\PulseSynchronizer.sv')
        )
        $rtl = Join-Path $root 'src'
        if ($variant -eq 'legacy') {
            $rtl = Join-Path $PSScriptRoot 'legacy'
            New-Item -ItemType Directory -Force $rtl | Out-Null
            foreach ($name in @('VGA_Timing.sv', 'FramebufferController.sv')) {
                $content = & git -C $root show "${LegacyRev}:src/$name"
                if ($LASTEXITCODE -ne 0) { throw "git show fallito: $name a $LegacyRev" }
                $content | Set-Content -LiteralPath (Join-Path $rtl $name) -Encoding utf8
            }
            $defines += '-DLEGACY'
            Write-Host "RTL storico: $LegacyRev"
        } elseif ($variant -eq 'current') {
            $defines += '-DREAL_FIFO'
            $sources += Join-Path $rtl 'FramebufferFifo.sv'
        }
        $sources += Join-Path $rtl 'VGA_Timing.sv'
        $sources += Join-Path $rtl 'FramebufferController.sv'
        Write-Host "Compilazione ($variant)..."
        try {
            # Explicit top: do not elaborate unused models as additional roots.
            Invoke-LoggedProcess -FilePath $compiler -Arguments (@('-g2012', '-s', 'tb_frame_resync') + $defines + @('-o', $vvp) + $sources) -LogPath $compileLog -TimeoutSeconds $TimeoutSeconds
        } catch {
            if (Test-Path -LiteralPath $vvp) { Remove-Item -LiteralPath $vvp }
            throw
        }
        if (-not (Test-Path -LiteralPath $vvp -PathType Leaf)) { throw 'Compilazione senza output' }
        Write-Host "Simulazione ($variant), limite reale $TimeoutSeconds s..."
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        # -i disables stdout buffering and makes each frame visible immediately.
        Invoke-LoggedProcess -FilePath $runtime -Arguments @('-i', '-N', $vvp) -LogPath $runLog -TimeoutSeconds $TimeoutSeconds
        $timer.Stop()
        if (-not (Select-String -LiteralPath $runLog -Pattern '^PASS: frame_resync ' -Quiet)) {
            throw "Simulazione terminata senza PASS: $runLog"
        }
        Write-Host ("OK {0}: {1:N1} s (log: {2})" -f $variant, $timer.Elapsed.TotalSeconds, $runLog)
    }
} finally {
    $env:PATH = $savedPath
    $env:YOSYSHQ_ROOT = $savedRoot
}
