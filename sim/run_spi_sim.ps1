param(
    [string]$OssCadSuite = 'C:\oss-cad-suite',
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 60
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools\Invoke-LoggedProcess.ps1')
$build = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force $build | Out-Null
foreach ($top in @('tb_spi_slave', 'tb_spi_diagnostic', 'tb_spi_directions', 'tb_spi_framebuffer', 'tb_font_store', 'tb_text_renderer', 'tb_line_renderer')) {
$vvp = Join-Path $build ($top + '.vvp')
$compileLog = Join-Path $build ($top + '_compile.log')
$runLog = Join-Path $build ($top + '_run.log')
foreach ($old in @($vvp, $compileLog, $runLog)) {
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old }
}
$savedPath = $env:PATH
$savedRoot = $env:YOSYSHQ_ROOT
try {
    $env:YOSYSHQ_ROOT = "$OssCadSuite\"
    $env:PATH = "$OssCadSuite\bin;$OssCadSuite\lib;$savedPath"
    Invoke-LoggedProcess -FilePath (Join-Path $OssCadSuite 'bin\iverilog.exe') -Arguments @(
        '-g2012', '-Wall', '-DSIMULATION', '-s', $top, '-o', $vvp,
        (Join-Path $root 'src\SpiSlave.sv'),
        (Join-Path $root 'src/SpiDiagnostic.sv'),
        (Join-Path $root 'src/SpiFramebuffer.sv'),
        (Join-Path $root 'src/UserFlashReader.sv'),
        (Join-Path $root 'src/FontStore.sv'),
        (Join-Path $root 'src/TextRenderer.sv'),
        (Join-Path $root 'src/FramebufferController.sv'),
        (Join-Path $PSScriptRoot ($top + '.sv'))
    ) -LogPath $compileLog -TimeoutSeconds $TimeoutSeconds
    Invoke-LoggedProcess -FilePath (Join-Path $OssCadSuite 'bin\vvp.exe') -Arguments @('-N', $vvp) -LogPath $runLog -TimeoutSeconds $TimeoutSeconds
    if (-not (Select-String -LiteralPath $runLog -Pattern ('^PASS: ' + $top.Substring(3) + ' ') -Quiet)) {
        throw 'Simulazione SPI terminata senza PASS'
    }
} finally {
    $env:PATH = $savedPath
    $env:YOSYSHQ_ROOT = $savedRoot
}

}
