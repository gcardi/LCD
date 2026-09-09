param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+$')][string]$SerialNumber,
    [switch]$ReadOnly,
    [string]$ProgrammerPath,
    [ValidateRange(5,120)][int]$TimeoutSeconds=20
)
$ErrorActionPreference='Stop'
if((Get-Content (Join-Path $PSScriptRoot 'Core/Inc/spi_diag_config.h') -Raw) -match '#define SPI_DIAG_MATRIX 1') {
    throw 'Matrice diagnostica abilitata: usare diagnose-hardware.ps1 -RestoreSelfTest -SerialNumber <seriale> prima del collaudo normale.'
}
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'tools/Invoke-LoggedProcess.ps1')
if(-not $ProgrammerPath) {
    $found=Get-Command STM32_Programmer_CLI.exe -ErrorAction SilentlyContinue
    if($found) {$ProgrammerPath=$found.Source}
    else {$ProgrammerPath=(Get-ChildItem 'C:/ST/STM32CubeCLT_*/STM32CubeProgrammer/bin/STM32_Programmer_CLI.exe' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName}
}
if(-not $ProgrammerPath) {throw 'CubeProgrammer CLI non trovato'}
$build=Join-Path $PSScriptRoot 'build/Debug'
New-Item -ItemType Directory -Force $build | Out-Null
$resultPath=Join-Path $build 'hardware-result.json'
if(Test-Path $resultPath) {Remove-Item -LiteralPath $resultPath}
if(-not $ReadOnly) {
    & (Join-Path $repoRoot 'sim/run_spi_sim.ps1')
    & (Join-Path $repoRoot 'build.ps1') -Program
    & (Join-Path $PSScriptRoot 'build.ps1') -Program -SerialNumber $SerialNumber -ProgrammerPath $ProgrammerPath
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
    Invoke-LoggedProcess -FilePath $ProgrammerPath -Arguments @('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000','-u',$address,'48',$dump) -LogPath (Join-Path $build 'hardware-read.log') -TimeoutSeconds $TimeoutSeconds
    $bytes=[IO.File]::ReadAllBytes($dump)
    if($bytes.Length -ne 48) {throw 'Dump risultato troncato'}
    $names=@('magic','version','state','transfers','checked_bytes','mismatches','first_bad_index','expected','actual','hal_error','elapsed_ms','sck_hz')
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
$result | ConvertTo-Json | Set-Content -LiteralPath $resultPath
if($result.magic -ne 0x53504954 -or $result.version -ne 1 -or $result.state -ne 2 -or $result.transfers -ne 40 -or $result.checked_bytes -ne 34992 -or $result.mismatches -ne 0 -or $result.hal_error -ne 0 -or -not $result.gpio_probe.all_match) {
    throw "Test hardware NON superato (timeout/errore): $($result | ConvertTo-Json -Compress)"
}
Write-Host "PASS: SPI DMA, $($result.transfers) trasferimenti, $($result.checked_bytes) byte verificati, $($result.elapsed_ms) ms."
Write-Host "Risultato: $resultPath"
