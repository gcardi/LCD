<#
.SYNOPSIS
Build CMake e, con -Program, upload/verifica/reset tramite ST-LINK SWD.
.EXAMPLE
.\build.ps1
.EXAMPLE
.\build.ps1 -ListProbes
.EXAMPLE
.\build.ps1 -Program -SerialNumber 35FF6C064D53373238602143
#>
param(
    [ValidateSet('Debug', 'Release')][string]$Preset = 'Debug',
    [switch]$Program,
    [switch]$ListProbes,
    [string]$SerialNumber,
    [string]$ProgrammerPath,
    [ValidateRange(1, 24000)][int]$SwdFrequencyKHz = 1000,
    [switch]$UnderReset,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'tools/Invoke-LoggedProcess.ps1')
$logDir = Join-Path $PSScriptRoot "build/$Preset"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

if ($Program -or $ListProbes) {
    if (-not $ProgrammerPath) {
        $onPath = Get-Command STM32_Programmer_CLI.exe -ErrorAction SilentlyContinue
        if ($onPath) { $ProgrammerPath = $onPath.Source }
        else {
            $candidates = @(Get-ChildItem 'C:/ST/STM32CubeCLT_*/STM32CubeProgrammer/bin/STM32_Programmer_CLI.exe' -File -ErrorAction SilentlyContinue)
            $selected = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($selected) { $ProgrammerPath = $selected.FullName }
        }
    }
    if (-not $ProgrammerPath -or -not (Test-Path -LiteralPath $ProgrammerPath -PathType Leaf)) {
        throw 'STM32CubeProgrammer CLI non trovato: specificare -ProgrammerPath.'
    }
}
if ($ListProbes) {
    Invoke-LoggedProcess -FilePath $ProgrammerPath -Arguments @('-l', 'stlink') -LogPath (Join-Path $logDir 'probes.log') -TimeoutSeconds $TimeoutSeconds
    return
}
if ($Program -and [string]::IsNullOrWhiteSpace($SerialNumber)) {
    throw 'Specificare -SerialNumber per selezionare la sonda; usare -ListProbes per elencarle.'
}
if ($SerialNumber -and $SerialNumber -notmatch '^[A-Za-z0-9]+$') {
    throw 'SerialNumber non valido.'
}
$cmake = (Get-Command cmake -ErrorAction Stop).Source
Push-Location $PSScriptRoot
try {
    Invoke-LoggedProcess -FilePath $cmake -Arguments @('--preset', $Preset) -LogPath (Join-Path $logDir 'configure.log') -TimeoutSeconds $TimeoutSeconds
    Invoke-LoggedProcess -FilePath $cmake -Arguments @('--build', '--preset', $Preset) -LogPath (Join-Path $logDir 'build.log') -TimeoutSeconds $TimeoutSeconds
    $elf = Join-Path $logDir 'WeAct_H743_SPI.elf'
    if (-not (Test-Path -LiteralPath $elf -PathType Leaf)) { throw "ELF non generato: $elf" }
    if ($Program) {
        $connection = @('-c', 'port=SWD', "sn=$SerialNumber", "freq=$SwdFrequencyKHz")
        if ($UnderReset) { $connection += @('mode=UR', 'reset=HWrst') }
        else { $connection += 'mode=NORMAL' }
        # ELF contains addresses. No mass erase or option-byte modifications.
        # Verify before reset/run; never program after a failed build.
        Invoke-LoggedProcess -FilePath $ProgrammerPath -Arguments ($connection + @('-w', $elf, '-v', '-rst')) -LogPath (Join-Path $logDir 'program.log') -TimeoutSeconds $TimeoutSeconds
        Write-Host 'Upload, verifica e reset completati.'
    }
    Write-Host "ELF: $elf"
} finally {
    Pop-Location
}
