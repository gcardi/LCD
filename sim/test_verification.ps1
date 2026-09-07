<#
.SYNOPSIS
    Negative tests: prove the runner, scoreboard and timing gate reject errors.
.DESCRIPTION
    Run after build.ps1. Uses the actual Gowin report and disposable copies
    under sim/build/verification_checks; never modifies project RTL.
#>
param(
    [string]$OssCadSuite = 'C:\oss-cad-suite',
    [string]$ReportPath = (Join-Path $PSScriptRoot '..\impl\pnr\LCD.tr')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path $PSScriptRoot 'build\verification_checks'
New-Item -ItemType Directory -Force $scratch | Out-Null
. (Join-Path $root 'tools\Invoke-LoggedProcess.ps1')
$script:passed = 0
function Expect-Failure([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    if (-not $failure -or $failure -notmatch $Pattern) {
        throw "Negative test '$Name': atteso '$Pattern', ottenuto '$failure'"
    }
    $script:passed++
    Write-Host "PASS negativo: $Name"
}

# Use the real report, not a hand-built approximation of Gowin's format.
$timingGate = Join-Path $root 'tools\Test-TimingReport.ps1'
& $timingGate -ReportPath $ReportPath | Out-Null
$original = Get-Content -LiteralPath $ReportPath -Raw
$reportFixture = Join-Path $scratch 'mutated.tr'
# Keep numerical mutations valid across place-and-route seeds. The project
# currently has residual calibration violations; a fully clean new baseline
# will need its own failing-path fixture instead of silently skipping cases.
$firstViolation = [regex]::Match($original, '(?m)^\s+\d+\s+(-\d+\.\d+)\s+psram_inst/u_psram_top/u_psram_init/calib_0_s\d+/Q')
if (-not $firstViolation.Success) { throw 'Fixture: nessun percorso di calibrazione negativo da mutare' }
$setupCount = [int][regex]::Match($original, '<Numbers of Setup Violated Endpoints>:(\d+)').Groups[1].Value
$pulsePattern = '(?s)(\r?\n3\.2 Minimum Pulse Width Table\r?\n.*?\r?\n\s+1\s+)\d+\.\d+'
$mutations = @(
    @{ Name = 'nuova violazione interna IP'; Text = $original.Replace('calib_0_s0/Q', 'config_done_s0/Q'); Error = 'fuori baseline' },
    @{ Name = 'percorso RTL verso IP'; Text = $original.Replace('psram_inst/u_psram_top/u_psram_init/calib_0_s0/Q', 'framebuffer_controller_inst/cmd_en_s0/Q'); Error = 'fuori baseline' },
    @{ Name = 'slack oltre limite'; Text = $original.Replace($firstViolation.Groups[1].Value, '-2.000'); Error = 'fuori baseline' },
    @{ Name = 'hold negativo'; Text = $original.Replace('<Numbers of Hold Violated Endpoints>:0', '<Numbers of Hold Violated Endpoints>:1'); Error = 'Violazioni hold' },
    @{ Name = 'endpoint non coperti'; Text = $original.Replace("<Numbers of Setup Violated Endpoints>:$setupCount", "<Numbers of Setup Violated Endpoints>:$($setupCount - 1)"); Error = 'Copertura setup incompleta' },
    @{ Name = 'report troncato'; Text = $original.Substring(0, $original.IndexOf('3.1.4 Removal Paths Table', $original.IndexOf('Note:Core Timing Report'))); Error = 'Tabella Removal' },
    @{ Name = 'clock rallentato'; Text = $original -replace '(?m)^(\s+\d+\s+psram_clk_81\s+)\d+\.\d+\(MHz\)', '${1}40.000(MHz)'; Error = 'Vincolo clock diverso' },
    @{ Name = 'clock memoria modificato'; Text = $original -replace '(?m)^(\s+\d+\s+mem_clk_162\s+Base\s+)\d+\.\d+', '${1}10.000'; Error = 'Periodo mem_clk_162' },
    @{ Name = 'pulse width negativo'; Text = $original -replace $pulsePattern, '${1}-0.100'; Error = 'pulse width' }
)
foreach ($mutation in $mutations) {
    if ($mutation.Text -ceq $original) { throw "Fixture non applicabile: $($mutation.Name); aggiornare al report corrente" }
    $mutation.Text | Set-Content -LiteralPath $reportFixture -Encoding utf8
    Expect-Failure $mutation.Name { & $timingGate -ReportPath $reportFixture } $mutation.Error
}
Expect-Failure 'report mancante' { & $timingGate -ReportPath (Join-Path $scratch 'missing.tr') } 'does not exist|non esiste|Cannot find|trovare'

# Exercise the public runner with the real compiler/runtime and a tiny bench.
# A prior valid .vvp exists before the syntax error is introduced.
$fixture = Join-Path $scratch 'runner fixture'
foreach ($dir in @('sim', 'src', 'tools')) {
    New-Item -ItemType Directory -Force (Join-Path $fixture $dir) | Out-Null
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run_sim.ps1') -Destination (Join-Path $fixture 'sim\run_sim.ps1')
Copy-Item -LiteralPath (Join-Path $root 'tools\Invoke-LoggedProcess.ps1') -Destination (Join-Path $fixture 'tools\Invoke-LoggedProcess.ps1')
foreach ($file in @('sim\models.sv', 'src\ResetSynchronizer.sv', 'src\PulseSynchronizer.sv', 'src\FramebufferFifo.sv', 'src\VGA_Timing.sv', 'src\FramebufferController.sv')) {
    '// empty fixture source' | Set-Content -LiteralPath (Join-Path $fixture $file)
}
$fixtureBench = Join-Path $fixture 'sim\tb_frame_resync.sv'
$fixtureRunner = Join-Path $fixture 'sim\run_sim.ps1'
'module tb_frame_resync; initial begin $display("PASS: frame_resync fixture"); $finish; end endmodule' | Set-Content -LiteralPath $fixtureBench
& $fixtureRunner -OssCadSuite $OssCadSuite
'syntax error deliberately injected' | Set-Content -LiteralPath $fixtureBench
Expect-Failure 'compilazione fallita con vvp precedente' { & $fixtureRunner -OssCadSuite $OssCadSuite } 'codice'
foreach ($stale in @('tb_current.vvp', 'run_current.log')) {
    if (Test-Path -LiteralPath (Join-Path $fixture "sim\build\$stale")) { throw "Artefatto obsoleto conservato: $stale" }
}
'module tb_frame_resync; initial $finish; endmodule' | Set-Content -LiteralPath $fixtureBench
Expect-Failure 'exit zero senza PASS' { & $fixtureRunner -OssCadSuite $OssCadSuite } 'senza PASS'
'module tb_frame_resync; initial $fatal(1, "intentional"); endmodule' | Set-Content -LiteralPath $fixtureBench
Expect-Failure 'fatal del simulatore' { & $fixtureRunner -OssCadSuite $OssCadSuite } 'codice'
'module tb_frame_resync; initial forever #1; endmodule' | Set-Content -LiteralPath $fixtureBench
Expect-Failure 'watchdog reale' { & $fixtureRunner -OssCadSuite $OssCadSuite -TimeoutSeconds 2 } 'TIMEOUT reale'

# Mutate actual pipeline signals via a separate simulation-only root. The
# behavioural FIFO keeps these negative tests short; current tests the real FIFO.
$savedPath = $env:PATH; $savedRoot = $env:YOSYSHQ_ROOT
try {
    $env:YOSYSHQ_ROOT = "$OssCadSuite\"
    $env:PATH = "$OssCadSuite\bin;$OssCadSuite\lib;$savedPath"
    $compiler = Join-Path $OssCadSuite 'bin\iverilog.exe'
    $runtime = Join-Path $OssCadSuite 'bin\vvp.exe'
    $injector = Join-Path $scratch 'injector.sv'
    $binary = Join-Path $scratch 'negative.vvp'
    $sources = @(
        (Join-Path $PSScriptRoot 'tb_frame_resync.sv'),
        (Join-Path $PSScriptRoot 'models.sv'),
        (Join-Path $root 'src\ResetSynchronizer.sv'),
        (Join-Path $root 'src\PulseSynchronizer.sv'),
        (Join-Path $root 'src\VGA_Timing.sv'),
        (Join-Path $root 'src\FramebufferController.sv'), $injector
    )
    $cases = @(
        @{ Name = 'timing'; Code = 'initial begin #1000; force tb_frame_resync.vga.LCD_HSYNC = 1; end'; Args = @(); Error = 'Timing:' },
        @{ Name = 'audit'; Code = 'initial begin wait(tb_frame_resync.cmd_en && !tb_frame_resync.cmd); tb_frame_resync.psram.fb[0] = 0; end'; Args = @(); Error = '\[audit\] FALLITO' },
        @{ Name = 'sim_timeout'; Code = ''; Args = @('+TIMEOUT_NS=1000'); Error = 'TIMEOUT simulato' },
        @{ Name = 'no_underrun'; Code = ''; Args = @('+FAULT_US=0'); Error = 'Iniezione inefficace' }
    )
    foreach ($case in $cases) {
        ('`timescale 1ns/1ps' + "`nmodule injector; " + $case.Code + "`nendmodule") | Set-Content -LiteralPath $injector
        Invoke-LoggedProcess -FilePath $compiler -Arguments (@('-g2012', '-s', 'tb_frame_resync', '-s', 'injector', '-o', $binary) + $sources) -LogPath (Join-Path $scratch "compile_$($case.Name).log")
        $log = Join-Path $scratch "run_$($case.Name).log"
        Expect-Failure "scoreboard $($case.Name)" {
            Invoke-LoggedProcess -FilePath $runtime -Arguments (@('-i', '-N', $binary) + $case.Args) -LogPath $log -TimeoutSeconds 300
        } 'codice'
        if (-not (Select-String -LiteralPath $log -Pattern $case.Error -Quiet)) { throw "Diagnostica errata: $log" }
    }
} finally {
    $env:PATH = $savedPath; $env:YOSYSHQ_ROOT = $savedRoot
}
Write-Host "PASS: verification_checks ($script:passed errori riconosciuti)"
