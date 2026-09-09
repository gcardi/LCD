param(
    [string]$Bitstream = (Join-Path $PSScriptRoot 'impl\pnr\LCD.fs'),
    [string]$UserFlash = (Join-Path $PSScriptRoot 'fonts\user_flash_fonts.fi')
)

$ErrorActionPreference = 'Stop'
$programmer = 'C:\Program Files\Gowin\Gowin_V1.9.12.01_x64\IDE\bin\Gowin_V1.9.12.01_x64\Programmer\bin\programmer_cli.exe'
foreach($file in @($programmer,$Bitstream,$UserFlash)) {
    if(-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "File non trovato: $file" }
}
$resolvedBitstream=(Resolve-Path -LiteralPath $Bitstream).Path
$resolvedUserFlash=(Resolve-Path -LiteralPath $UserFlash).Path
Write-Host 'Programmazione e verifica della Embedded Flash e della User Flash...'
Write-Host "Bitstream:  $resolvedBitstream"
Write-Host "User Flash: $resolvedUserFlash"
& $programmer --device GW1NR-9C --operation_index 6 --cable-index 1 `
    --fsFile $resolvedBitstream --fiFile $resolvedUserFlash
if($LASTEXITCODE -ne 0) { throw "Programmazione Gowin fallita con codice $LASTEXITCODE" }
Write-Host 'Embedded Flash e User Flash programmate e verificate.'
