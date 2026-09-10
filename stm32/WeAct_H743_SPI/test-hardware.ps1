param(
    [ValidateSet('Debug', 'Release')][string]$Preset = 'Debug',
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+$')][string]$SerialNumber,
    [switch]$ReadOnly,
    [switch]$RequireGraphics,
    [switch]$RequireStress,
    [switch]$RequireText,
    [switch]$RequireFPGAText,
    [string]$ProgrammerPath,
    [ValidateRange(5,120)][int]$TimeoutSeconds=20
)
$ErrorActionPreference='Stop'
if((Get-Content (Join-Path $PSScriptRoot 'Core/Inc/spi_diag_config.h') -Raw) -match '#define SPI_DIAG_MATRIX 1') {
    throw 'Matrice diagnostica abilitata: usare diagnose-hardware.ps1 -RestoreSelfTest -SerialNumber <seriale> prima del collaudo normale.'
}
if(($RequireGraphics -or $RequireStress) -and
   (Get-Content (Join-Path $PSScriptRoot 'Core/Inc/spi_diag_config.h') -Raw) -match '#define LCD_BOOT_TESTS 0') {
    throw 'Test grafici disabilitati: impostare LCD_BOOT_TESTS 1 in Core/Inc/spi_diag_config.h e ricompilare/caricare; ripristinare 0 per avvio uniforme.'
}
if($RequireText -and
   (Get-Content (Join-Path $PSScriptRoot 'Core/Inc/spi_diag_config.h') -Raw) -match '#define LCD_TEXT_DEMO 0') {
    throw 'Demo testo disabilitata: impostare LCD_TEXT_DEMO 1 in Core/Inc/spi_diag_config.h e ricompilare/caricare.'
}
if($RequireFPGAText -and
   (Get-Content (Join-Path $PSScriptRoot 'Core/Inc/spi_diag_config.h') -Raw) -match '#define LCD_FPGA_TEXT_DEMO 0') {
    throw 'Demo testo FPGA disabilitata: impostare LCD_FPGA_TEXT_DEMO 1 in Core/Inc/spi_diag_config.h e ricompilare/caricare.'
}
# Il gate finale pretende gpio_probe.all_match, ma la prova GPIO costa ~800 ms
# ed e' disattivabile: senza di essa il collaudo fallirebbe senza spiegazione.
if((Get-Content (Join-Path $PSScriptRoot 'Core/Inc/spi_diag_config.h') -Raw) -match '#define SPI_GPIO_PROBE 0') {
    throw 'Prova GPIO disabilitata: impostare SPI_GPIO_PROBE 1 in Core/Inc/spi_diag_config.h e ricompilare/caricare; rimetterlo a 0 per un avvio rapido.'
}
# -RequireStress pretende oltre 1.000.000 di byte di eco e ogni round ne vale
# 4374, quindi servono almeno 229 round. Va detto prima di compilare e caricare.
if($RequireStress) {
    $roundsPre=Get-Content (Join-Path $PSScriptRoot 'Core/Inc/spi_diag_config.h') -Raw
    if($roundsPre -match '#define SPI_SELFTEST_ROUNDS (\d+)' -and [int]$Matches[1] -lt 229) {
        throw "SPI_SELFTEST_ROUNDS=$([int]$Matches[1]): la qualifica di stress richiede almeno 229 round, cioe' 1.000.000 di byte. Portarlo a 240 in Core/Inc/spi_diag_config.h e ricompilare."
    }
}
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'tools/Invoke-LoggedProcess.ps1')
if(-not $ProgrammerPath) {
    $found=Get-Command STM32_Programmer_CLI.exe -ErrorAction SilentlyContinue
    if($found) {$ProgrammerPath=$found.Source}
    else {$ProgrammerPath=(Get-ChildItem 'C:/ST/STM32CubeCLT_*/STM32CubeProgrammer/bin/STM32_Programmer_CLI.exe' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName}
}
if(-not $ProgrammerPath) {throw 'CubeProgrammer CLI non trovato'}
$build=Join-Path $PSScriptRoot "build/$Preset"
New-Item -ItemType Directory -Force $build | Out-Null
$resultPath=Join-Path $build 'hardware-result.json'
if(Test-Path $resultPath) {Remove-Item -LiteralPath $resultPath}
if(-not $ReadOnly) {
    & (Join-Path $repoRoot 'sim/run_spi_sim.ps1')
    & (Join-Path $repoRoot 'build.ps1') -Program
    & (Join-Path $PSScriptRoot 'build.ps1') -Preset $Preset -Program -SerialNumber $SerialNumber -ProgrammerPath $ProgrammerPath
}
$elf=Join-Path $build 'WeAct_H743_SPI.elf'
$symbols=& arm-none-eabi-nm $elf
if($LASTEXITCODE -ne 0) {throw 'Lettura simboli ELF fallita'}
$symbol=@($symbols | Where-Object {$_ -match '^[0-9a-fA-F]+\s+\w\s+g_spi_test$'})
if($symbol.Count -ne 1) {throw 'Simbolo g_spi_test mancante o ambiguo'}
$address='0x'+($symbol[0] -split '\s+')[0]
$dump=Join-Path $build 'hardware-result.bin'
$timer=[Diagnostics.Stopwatch]::StartNew()
do {
    if(Test-Path $dump) {Remove-Item -LiteralPath $dump}
    Invoke-LoggedProcess -FilePath $ProgrammerPath -Arguments @('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000','-u',$address,'56',$dump) -LogPath (Join-Path $build 'hardware-read.log') -TimeoutSeconds $TimeoutSeconds
    $bytes=[IO.File]::ReadAllBytes($dump)
    if($bytes.Length -ne 56) {throw 'Dump risultato troncato'}
    $names=@('magic','version','state','transfers','checked_bytes','mismatches','first_bad_index','expected','actual','hal_error','elapsed_ms','sck_hz','ready_ms','ready_attempts')
    $result=[ordered]@{}
    for($i=0;$i -lt $names.Count;$i++) {$result[$names[$i]]=[BitConverter]::ToUInt32($bytes,4*$i)}
    if($result.magic -eq 0x53504954 -and $result.version -eq 1 -and $result.state -in @(2,3)) {break}
    Start-Sleep -Milliseconds 250
} while($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
$result['elf_sha256']=(Get-FileHash $elf -Algorithm SHA256).Hash
$result['read_only']=[bool]$ReadOnly
$probeSymbol=@($symbols | Where-Object {$_ -match '^[0-9a-fA-F]+\s+\w\s+g_spi_gpio_probe$'})
if($probeSymbol.Count -eq 1) {
    $probeAddress='0x'+($probeSymbol[0] -split '\s+')[0]
    $probeDump=Join-Path $build 'hardware-gpio.bin'
    if(Test-Path $probeDump) {Remove-Item -LiteralPath $probeDump}
    Invoke-LoggedProcess -FilePath $ProgrammerPath -Arguments @('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000','-u',$probeAddress,'24',$probeDump) -LogPath (Join-Path $build 'hardware-gpio.log') -TimeoutSeconds $TimeoutSeconds
    $probeBytes=[IO.File]::ReadAllBytes($probeDump)
    if($probeBytes.Length -ne 24) {throw 'Dump GPIO troncato'}
    $probe=[ordered]@{expected='A5 3C 4D 5E 6F 80 91 A2'}
    $pullNames=@('no_pull','pull_up','pull_down')
    for($p=0;$p -lt 3;$p++) {
        $probe[$pullNames[$p]]=($probeBytes[($p*8)..($p*8+7)] | ForEach-Object {$_.ToString('X2')}) -join ' '
    }
    $probe['all_match']=($probe.no_pull -eq $probe.expected -and $probe.pull_up -eq $probe.expected -and $probe.pull_down -eq $probe.expected)
    $result['gpio_probe']=$probe
}
if ($RequireGraphics) {
    $graphicsSymbol=@($symbols | Where-Object {$_ -match '^[0-9a-fA-F]+\s+\w\s+g_lcd_demo_state$'})
    if($graphicsSymbol.Count -ne 1) {throw 'Simbolo demo grafica mancante'}
    $graphicsAddress='0x'+($graphicsSymbol[0] -split '\s+')[0]
    $graphicsDump=Join-Path $build 'hardware-graphics.bin'
    $graphicsTimer=[Diagnostics.Stopwatch]::StartNew()
    do {
        if(Test-Path $graphicsDump) {Remove-Item -LiteralPath $graphicsDump}
        Invoke-LoggedProcess -FilePath $ProgrammerPath -Arguments @('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000','-u',$graphicsAddress,'4',$graphicsDump) -LogPath (Join-Path $build 'hardware-graphics.log') -TimeoutSeconds $TimeoutSeconds
        $graphicsBytes=[IO.File]::ReadAllBytes($graphicsDump)
        if($graphicsBytes.Length -ne 4) {throw 'Dump grafico troncato'}
        $result['graphics_state']=[BitConverter]::ToUInt32($graphicsBytes,0)
        if($result.graphics_state -ne 1) {break}
        Start-Sleep -Milliseconds 100
    } while($graphicsTimer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
}
if($RequireText) {
    $textSymbol=@($symbols | Where-Object {$_ -match '^[0-9a-fA-F]+\s+\w\s+g_lcd_text_demo_state$'})
    if($textSymbol.Count -ne 1) {throw 'Simbolo demo testo mancante'}
    $textAddress='0x'+($textSymbol[0] -split '\s+')[0]
    $textDump=Join-Path $build 'hardware-text.bin'
    $textTimer=[Diagnostics.Stopwatch]::StartNew()
    do {
        if(Test-Path $textDump) {Remove-Item -LiteralPath $textDump}
        Invoke-LoggedProcess -FilePath $ProgrammerPath -Arguments @('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000','-u',$textAddress,'4',$textDump) -LogPath (Join-Path $build 'hardware-text.log') -TimeoutSeconds $TimeoutSeconds
        $textBytes=[IO.File]::ReadAllBytes($textDump)
        if($textBytes.Length -ne 4) {throw 'Dump demo testo troncato'}
        $result['text_state']=[BitConverter]::ToUInt32($textBytes,0)
        if($result.text_state -ne 1) {break}
        Start-Sleep -Milliseconds 100
    } while($textTimer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
}
if($RequireFPGAText) {
    $fpgaTextSymbol=@($symbols | Where-Object {$_ -match '^[0-9a-fA-F]+\s+\w\s+g_lcd_fpga_text_demo_state$'})
    if($fpgaTextSymbol.Count -ne 1) {throw 'Simbolo demo testo FPGA mancante'}
    $fpgaTextAddress='0x'+($fpgaTextSymbol[0] -split '\s+')[0]
    $fpgaTextDump=Join-Path $build 'hardware-fpga-text.bin'
    $fpgaTextTimer=[Diagnostics.Stopwatch]::StartNew()
    do {
        if(Test-Path $fpgaTextDump) {Remove-Item -LiteralPath $fpgaTextDump}
        Invoke-LoggedProcess -FilePath $ProgrammerPath -Arguments @('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000','-u',$fpgaTextAddress,'4',$fpgaTextDump) -LogPath (Join-Path $build 'hardware-fpga-text.log') -TimeoutSeconds $TimeoutSeconds
        $fpgaTextBytes=[IO.File]::ReadAllBytes($fpgaTextDump)
        if($fpgaTextBytes.Length -ne 4) {throw 'Dump demo testo FPGA troncato'}
        $result['fpga_text_state']=[BitConverter]::ToUInt32($fpgaTextBytes,0)
        if($result.fpga_text_state -ne 1) {break}
        Start-Sleep -Milliseconds 100
    } while($fpgaTextTimer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $errorSymbol=@($symbols | Where-Object {$_ -match '^[0-9a-fA-F]+\s+\w\s+g_lcd_error$'})
    if($errorSymbol.Count -eq 1) {
        $errorAddress='0x'+($errorSymbol[0] -split '\s+')[0]
        $errorDump=Join-Path $build 'hardware-lcd-error.bin'
        if(Test-Path $errorDump) {Remove-Item -LiteralPath $errorDump}
        Invoke-LoggedProcess -FilePath $ProgrammerPath -Arguments @('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000','-u',$errorAddress,'24',$errorDump) -LogPath (Join-Path $build 'hardware-lcd-error.log') -TimeoutSeconds $TimeoutSeconds
        $errorBytes=[IO.File]::ReadAllBytes($errorDump)
        if($errorBytes.Length -ne 24) {throw 'Dump errore LCD troncato'}
        $lcdError=[ordered]@{}
        $errorNames=@('phase','address','index','expected','actual','hal_error')
        for($i=0;$i -lt 6;$i++) {$lcdError[$errorNames[$i]]=[BitConverter]::ToUInt32($errorBytes,$i*4)}
        $result['lcd_error']=$lcdError
    }
}
$roundConfig=Get-Content (Join-Path $PSScriptRoot 'Core/Inc/spi_diag_config.h') -Raw
if($roundConfig -notmatch '#define SPI_SELFTEST_ROUNDS (\d+)') {throw 'Numero round non definito'}
$expectedRounds=[int]$Matches[1]
if($RequireStress) {
    $stressSymbol=@($symbols | Where-Object {$_ -match '^[0-9a-fA-F]+\s+\w\s+g_lcd_stress$'})
    if($stressSymbol.Count -ne 1) {throw 'Simbolo stress mancante'}
    $stressAddress='0x'+($stressSymbol[0] -split '\s+')[0]
    $stressDump=Join-Path $build 'hardware-stress.bin'
    $stressTimer=[Diagnostics.Stopwatch]::StartNew()
    do {
        if(Test-Path $stressDump) {Remove-Item -LiteralPath $stressDump}
        Invoke-LoggedProcess -FilePath $ProgrammerPath -Arguments @('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000','-u',$stressAddress,'24',$stressDump) -LogPath (Join-Path $build 'hardware-stress.log') -TimeoutSeconds $TimeoutSeconds
        $stressBytes=[IO.File]::ReadAllBytes($stressDump)
        if($stressBytes.Length -ne 24) {throw 'Dump stress troncato'}
        $stress=[ordered]@{}
        $stressNames=@('state','rectangles','pixels','packets','elapsed_ms','failed_rect')
        for($i=0;$i -lt 6;$i++) {$stress[$stressNames[$i]]=[BitConverter]::ToUInt32($stressBytes,$i*4)}
        if($stress.state -in @(2,3)) {break}
        Start-Sleep -Milliseconds 250
    } while($stressTimer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $result['stress']=$stress
    $errorSymbol=@($symbols | Where-Object {$_ -match '^[0-9a-fA-F]+\s+\w\s+g_lcd_error$'})
    if($errorSymbol.Count -eq 1) {
        $errorAddress='0x'+($errorSymbol[0] -split '\s+')[0]
        $errorDump=Join-Path $build 'hardware-lcd-error.bin'
        if(Test-Path $errorDump) {Remove-Item -LiteralPath $errorDump}
        Invoke-LoggedProcess -FilePath $ProgrammerPath -Arguments @('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000','-u',$errorAddress,'24',$errorDump) -LogPath (Join-Path $build 'hardware-lcd-error.log') -TimeoutSeconds $TimeoutSeconds
        $errorBytes=[IO.File]::ReadAllBytes($errorDump)
        if($errorBytes.Length -ne 24) {throw 'Dump errore LCD troncato'}
        $lcdError=[ordered]@{}
        $errorNames=@('phase','address','index','expected','actual','hal_error')
        for($i=0;$i -lt 6;$i++) {$lcdError[$errorNames[$i]]=[BitConverter]::ToUInt32($errorBytes,$i*4)}
        $result['lcd_error']=$lcdError
    }
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath
if($result.magic -ne 0x53504954 -or $result.version -ne 1 -or $result.state -ne 2 -or $result.transfers -ne ($expectedRounds*5) -or $result.checked_bytes -ne ($expectedRounds*4374) -or $result.mismatches -ne 0 -or $result.hal_error -ne 0 -or -not $result.gpio_probe.all_match) {
    throw "Test hardware NON superato (timeout/errore): $($result | ConvertTo-Json -Compress)"
}
if ($RequireGraphics -and $result.graphics_state -ne 2) {throw "Demo grafica NON superata: stato $($result.graphics_state)"}
if($RequireText -and $result.text_state -ne 2) {throw "Demo testo NON superata: stato $($result.text_state)"}
if($RequireFPGAText -and ($result.fpga_text_state -ne 2 -or $result.lcd_error.phase -ne 0)) {throw "Demo testo FPGA NON superata: $($result | ConvertTo-Json -Depth 5 -Compress)"}
if($RequireStress -and ($result.stress.state -ne 2 -or $result.stress.rectangles -ne 512 -or $result.stress.pixels -ne 354528 -or $result.stress.packets -ne 30035 -or $result.lcd_error.phase -ne 0 -or $result.checked_bytes -lt 1000000)) {throw "Stress NON superato: $($result | ConvertTo-Json -Depth 5 -Compress)"}
Write-Host "PASS: SPI DMA, $($result.transfers) trasferimenti, $($result.checked_bytes) byte verificati, $($result.elapsed_ms) ms."
Write-Host "Risultato: $resultPath"
