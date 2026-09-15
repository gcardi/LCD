param([switch]$RealFifo,[int]$TimeoutSeconds=600)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools/Invoke-LoggedProcess.ps1')
$variant=if($RealFifo){'real'}else{'model'}
$build=Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force $build | Out-Null
$vvp=Join-Path $build "double_buffer_$variant.vvp"
if(Test-Path $vvp){Remove-Item -LiteralPath $vvp}
$sources=@('src/TOP.sv','src/SpiSlave.sv','src/SpiFramebuffer.sv','src/TextRenderer.sv',
 'src/FontStore.sv','src/UserFlashReader.sv','src/FramebufferController.sv',
 'src/VGA_Timing.sv','src/ResetSynchronizer.sv','src/PulseSynchronizer.sv',
 'sim/models.sv','sim/tb_double_buffer.sv') | ForEach-Object {Join-Path $root $_}
$defines=@('-DSIMULATION')
if($RealFifo){$defines+='-DREAL_FIFO';$sources+=Join-Path $root 'src/FramebufferFifo.sv'}
Push-Location $root
try {
Invoke-LoggedProcess -FilePath 'C:/oss-cad-suite/bin/iverilog.exe' -Arguments (@('-g2012','-s','tb_double_buffer','-o',$vvp)+$defines+$sources) -LogPath "$build/double_buffer_${variant}_compile.log" -TimeoutSeconds 60
Invoke-LoggedProcess -FilePath 'C:/oss-cad-suite/bin/vvp.exe' -Arguments @('-i','-N',$vvp) -LogPath "$build/double_buffer_${variant}_run.log" -TimeoutSeconds $TimeoutSeconds
if(-not (Select-String "$build/double_buffer_${variant}_run.log" -Pattern '^PASS: double_buffer ' -Quiet)){throw 'Double buffering simulation failed'}

} finally {Pop-Location}

