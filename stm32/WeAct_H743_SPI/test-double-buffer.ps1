param(
 [ValidateSet('Debug','Release')][string]$Preset='Release',
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+$')][string]$SerialNumber,
 [switch]$ReadOnly,
 [switch]$RequireScroll
)
$ErrorActionPreference='Stop'
# Default follows the enabled demo; -RequireScroll also rejects a disabled one.
$config=Get-Content (Join-Path $PSScriptRoot 'Core/Inc/spi_diag_config.h') -Raw
$RequireScroll=$RequireScroll -or ($config -match '(?m)^#define LCD_SCROLL_DEMO 1\s*$')
if($RequireScroll){
 if($config -notmatch '#define LCD_SCROLL_DEMO 1' -or $config -notmatch '#define LCD_FPGA_TEXT_DEMO 1'){
  throw 'Scroll qualification requires LCD_SCROLL_DEMO=1 and LCD_FPGA_TEXT_DEMO=1'
 }
}
$resultStem=if($RequireScroll){'scroll'}else{'double-buffer'}
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'tools/Invoke-LoggedProcess.ps1')
$programmer=(Get-ChildItem 'C:/ST/STM32CubeCLT_*/STM32CubeProgrammer/bin/STM32_Programmer_CLI.exe' -File |
 Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
if(-not $programmer){throw 'CubeProgrammer not found'}
$build=Join-Path $PSScriptRoot "build/$Preset"
New-Item -ItemType Directory -Force $build | Out-Null
$resultPath=Join-Path $build "$resultStem-result.json"
if(Test-Path $resultPath){Remove-Item -LiteralPath $resultPath}
if(-not $ReadOnly){
 $manifest=Get-Content (Join-Path $root 'impl/verification.json') -Raw | ConvertFrom-Json
 $bitstream=Join-Path $root 'impl/pnr/LCD.fs'
 if((Get-FileHash $bitstream).Hash -ne $manifest.BitstreamSHA256){throw 'Bitstream does not match timing verification'}
 # Build MCU before either programming operation, then install matching FPGA first.
 & (Join-Path $PSScriptRoot 'build.ps1') -Preset $Preset
 & (Join-Path $root 'program_tang_nano_flash.ps1')
 & (Join-Path $PSScriptRoot 'build.ps1') -Preset $Preset -Program -SerialNumber $SerialNumber
}
$elf=Join-Path $build 'WeAct_H743_SPI.elf'
$symbols=& arm-none-eabi-nm -S $elf
if($LASTEXITCODE -ne 0){throw 'Cannot read ELF symbols'}
$names=@('g_spi_test','g_lcd_fpga_text_demo_state','g_lcd_error','g_lcd_clear_ms16',
 'g_lcd_present_count','g_lcd_present_ms','g_lcd_front_buffer','g_lcd_present_sequence',
 'g_fpga_irq_count','g_fpga_irq_pending','g_fpga_irq_level')
if($RequireScroll){$names+=@('g_lcd_scroll_demo_state','g_lcd_copy_count','g_lcd_scroll_count','g_lcd_copy_ms','g_lcd_scroll_ms')}
$entries=@{}
foreach($name in $names){
 $line=@($symbols | Where-Object {$_ -match ('^[0-9a-fA-F]+\s+[0-9a-fA-F]+\s+\w\s+'+$name+'$')})
 if($line.Count -ne 1){throw "Missing/ambiguous ELF symbol: $name"}
 $parts=$line[0] -split '\s+'
 $entries[$name]=@([Convert]::ToUInt32($parts[0],16),[Convert]::ToUInt32($parts[1],16))
}
$connection=@('-c','port=SWD',"sn=$SerialNumber",'mode=HOTPLUG','freq=1000')
# A read-only run must verify the firmware too, before interpreting its RAM.
$reference=Join-Path $build 'double-buffer-reference.bin'
$flash=Join-Path $build 'double-buffer-flash.bin'
& arm-none-eabi-objcopy -O binary $elf $reference
if($LASTEXITCODE -ne 0){throw 'objcopy failed'}
Invoke-LoggedProcess -FilePath $programmer -Arguments ($connection+@('-u','0x08000000',"$((Get-Item $reference).Length)",$flash)) -LogPath (Join-Path $build 'double-buffer-flash-read.log') -TimeoutSeconds 20
if((Get-FileHash $reference).Hash -ne (Get-FileHash $flash).Hash){throw 'Target flash differs from local ELF'}
$first=($entries.Values | ForEach-Object {$_[0]} | Measure-Object -Minimum).Minimum
$end=($entries.Values | ForEach-Object {$_[0]+$_[1]} | Measure-Object -Maximum).Maximum
if($first -lt 0x20000000 -or $end -gt 0x20020000){throw 'Result symbols are outside DTCM'}
$dump=Join-Path $build 'double-buffer-state.bin'
$timer=[Diagnostics.Stopwatch]::StartNew()
do {
 Invoke-LoggedProcess -FilePath $programmer -Arguments ($connection+@('-u',('0x{0:X8}' -f [uint32]$first),"$($end-$first)",$dump)) -LogPath (Join-Path $build 'double-buffer-state-read.log') -TimeoutSeconds 20
 $bytes=[IO.File]::ReadAllBytes($dump)
 if($bytes.Length -ne $end-$first){throw 'Truncated RAM dump'}
 $result=[ordered]@{read_at_utc=[DateTime]::UtcNow.ToString('o');elf_sha256=(Get-FileHash $elf).Hash;flash_verified=$true}
 foreach($name in $names){
  $values=@(for($i=0;$i -lt $entries[$name][1];$i+=4){[BitConverter]::ToUInt32($bytes,$entries[$name][0]-$first+$i)})
  $result[$name]=if($values.Count -eq 1){$values[0]}else{$values}
 }
 if($RequireScroll){
  if($result.g_lcd_scroll_demo_state -in @(2,3) -or $result.g_lcd_error[0] -ne 0){break}
 }elseif($result.g_lcd_fpga_text_demo_state -in @(2,3)){break}
 Start-Sleep -Milliseconds 500
}while($timer.Elapsed.TotalSeconds -lt 25)
$expectedPresents=if($RequireScroll){50}else{17}
$result.pass=($result.g_spi_test[0] -eq 0x53504954 -and $result.g_spi_test[1] -eq 1 -and
 $result.g_spi_test[2] -eq 2 -and $result.g_spi_test[3] -eq 5 -and
 $result.g_spi_test[4] -eq 4374 -and $result.g_spi_test[5] -eq 0 -and
 $result.g_spi_test[9] -eq 0 -and $result.g_spi_test[11] -eq 9375000 -and
 $result.g_lcd_fpga_text_demo_state -eq 2 -and $result.g_lcd_error[0] -eq 0 -and
 $result.g_lcd_present_count -eq $expectedPresents -and $result.g_fpga_irq_count -eq $expectedPresents -and
 $result.g_fpga_irq_pending -eq 0 -and $result.g_fpga_irq_level -eq 1)
if($RequireScroll){$result.pass=$result.pass -and $result.g_lcd_scroll_demo_state -eq 2 -and
 $result.g_lcd_copy_count -eq 1 -and $result.g_lcd_scroll_count -eq 32}
$result | ConvertTo-Json -Depth 4 | Set-Content $resultPath
$result | ConvertTo-Json -Depth 4 | Write-Host
if(-not $result.pass){throw "Double buffer hardware check failed: $resultPath"}
Write-Host "PASS: graphics hardware, $expectedPresents presentations and IRQ edges, no SPI/LCD errors"
