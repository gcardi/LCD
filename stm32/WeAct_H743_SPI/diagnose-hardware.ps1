param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+$')][string]$SerialNumber,
    [ValidateSet('echo','miso','mosi')][string]$Mode='echo',
    [ValidateRange(8,80)][int]$Rounds=8,
    [switch]$RestoreSelfTest
)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'tools/Invoke-LoggedProcess.ps1')
$modeNumber=@{echo=0;miso=1;mosi=2}[$Mode]
if($RestoreSelfTest) {
    $config=Join-Path $PSScriptRoot 'Core/Inc/spi_diag_config.h'
    $text=[IO.File]::ReadAllText($config) -replace '#define SPI_DIAG_MATRIX \d+','#define SPI_DIAG_MATRIX 0' -replace '#define SPI_DIAG_MODE \d+','#define SPI_DIAG_MODE 0'
    [IO.File]::WriteAllText($config,$text)
    $top=Join-Path $repoRoot 'src/TOP.sv'
    [IO.File]::WriteAllText($top,([IO.File]::ReadAllText($top) -replace 'SpiDiagnostic #\(\.MODE\(\d+\)\)','SpiDiagnostic #(.MODE(0))'))
    & (Join-Path $PSScriptRoot 'test-hardware.ps1') -SerialNumber $SerialNumber
    return
}
$build=Join-Path $PSScriptRoot 'build/Debug'
New-Item -ItemType Directory -Force $build | Out-Null
$archive=Join-Path $build ('diagnostic-'+$Mode+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory $archive | Out-Null
Push-Location $repoRoot
try {
    $config=Join-Path $PSScriptRoot 'Core/Inc/spi_diag_config.h'
    $text=[IO.File]::ReadAllText($config) -replace '#define SPI_DIAG_MATRIX \d+','#define SPI_DIAG_MATRIX 1' -replace '#define SPI_DIAG_MODE \d+',"#define SPI_DIAG_MODE $modeNumber"
    $text=$text -replace '#define SPI_DIAG_ROUNDS \d+',"#define SPI_DIAG_ROUNDS $Rounds"
    [IO.File]::WriteAllText($config,$text)
    $top=Join-Path $repoRoot 'src/TOP.sv'
    [IO.File]::WriteAllText($top,([IO.File]::ReadAllText($top) -replace 'SpiDiagnostic #\(\.MODE\(\d+\)\)',"SpiDiagnostic #(.MODE($modeNumber))"))
    $sdc=Join-Path $repoRoot 'src/LCD.sdc'
    [IO.File]::WriteAllText($sdc,([IO.File]::ReadAllText($sdc) -replace 'create_clock -name spi_clk -period \d+ -waveform \{0 \d+\}','create_clock -name spi_clk -period 80 -waveform {0 40}'))
    & ./sim/run_spi_sim.ps1
    & ./build.ps1 -Program
    & (Join-Path $PSScriptRoot 'build.ps1') -Program -SerialNumber $SerialNumber
    $programmer=(Get-Command STM32_Programmer_CLI.exe -ErrorAction SilentlyContinue).Source
    if(-not $programmer) {$programmer=(Get-ChildItem 'C:/ST/STM32CubeCLT_*/STM32CubeProgrammer/bin/STM32_Programmer_CLI.exe' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName}
    $elf=Join-Path $build 'WeAct_H743_SPI.elf'
    $symbols=& arm-none-eabi-nm $elf
    if($LASTEXITCODE -ne 0){throw 'nm failed'}
    $symbol=@($symbols | Where-Object {$_ -match '^([0-9a-fA-F]+)\s+\w\s+g_spi_diag$'})
    if($symbol.Count -ne 1){throw 'g_spi_diag symbol missing/ambiguous'}
    $address='0x'+($symbol[0] -split '\s+')[0]
    $dump=Join-Path $archive 'matrix.bin'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        Invoke-LoggedProcess -FilePath $programmer -Arguments @('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000','-u',$address,'20',$dump) -LogPath (Join-Path $archive 'read-header.log') -TimeoutSeconds 30
        $bytes=[IO.File]::ReadAllBytes($dump)
        if($bytes.Length -ne 20){throw 'Truncated header'}
        if([BitConverter]::ToUInt32($bytes,8) -eq 2){break}
        Start-Sleep -Milliseconds 250
    } while($timer.Elapsed.TotalSeconds -lt 120)
    if([BitConverter]::ToUInt32($bytes,0) -ne 0x44494147 -or [BitConverter]::ToUInt32($bytes,4) -ne 1 -or [BitConverter]::ToUInt32($bytes,8) -ne 2 -or [BitConverter]::ToUInt32($bytes,12) -ne $modeNumber -or [BitConverter]::ToUInt32($bytes,16) -ne 18){throw 'Matrix invalid/incomplete'}
    Invoke-LoggedProcess -FilePath $programmer -Arguments @('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000','-u',$address,'11036',$dump) -LogPath (Join-Path $archive 'read-matrix.log') -TimeoutSeconds 30
    $bytes=[IO.File]::ReadAllBytes($dump)
    if($bytes.Length -ne 11036){throw 'Truncated matrix'}
    $caseNames=@('hz','speed','repeat','transfers','checked','mismatches','hal_error','elapsed_ms','event_count')
    $eventNames=@('round','length','index','expected','actual','rx_prev','rx_next','expected_prev','expected_next')
    $cases=@()
    for($c=0;$c -lt 18;$c++) {
        $offset=20+$c*612
        $case=[ordered]@{}
        for($i=0;$i -lt 9;$i++){$case[$caseNames[$i]]=[BitConverter]::ToUInt32($bytes,$offset+$i*4)}
        if($case.event_count -gt 16){throw 'Invalid event count'}
        $case['events']=@()
        for($e=0;$e -lt $case.event_count;$e++) {
            $event=[ordered]@{}
            for($i=0;$i -lt 9;$i++){$event[$eventNames[$i]]=[BitConverter]::ToUInt32($bytes,$offset+36+$e*36+$i*4)}
            $case.events+=$event
        }
        $case['complete']=($case.hal_error -eq 0 -and $case.transfers -eq $(if($modeNumber -eq 2){$Rounds}else{5*$Rounds}) -and $case.checked -eq $(if($modeNumber -eq 2){4*$Rounds}else{4374*$Rounds}))
        $cases+=[pscustomobject]$case
    }
    Copy-Item $elf (Join-Path $archive 'firmware.elf')
    Copy-Item ./impl/pnr/LCD.fs (Join-Path $archive 'LCD.fs')
    Copy-Item ./impl/pnr/LCD.tr (Join-Path $archive 'LCD.tr')
    $result=[ordered]@{mode=$Mode;rounds=$Rounds;timestamp=(Get-Date -Format o);elf_sha256=(Get-FileHash $elf).Hash;bitstream_sha256=(Get-FileHash ./impl/pnr/LCD.fs).Hash;cases=$cases}
    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $archive 'result.json')
    $cases | Select-Object hz,speed,repeat,transfers,checked,mismatches,hal_error,complete | Format-Table | Out-Host
    Write-Host "Diagnostic results (speed 3=VERY_HIGH, 2=HIGH, 1=MEDIUM): $archive"
    if(@($cases | Where-Object {-not $_.complete}).Count){throw 'One or more cases incomplete/HAL error; see archived results'}
    # Data mismatches are diagnostic evidence, not a runner execution failure.
} finally {Pop-Location}
