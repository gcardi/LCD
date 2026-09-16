<#
.SYNOPSIS
    Fail-closed timing gate for the documented Gowin calibration exception.
#>
param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference = 'Stop'
$lines = Get-Content -LiteralPath $ReportPath
$report = $lines -join "`n"

foreach ($required in @(
    '<Tool Version>: V1.9.12.01 (64-bit)',
    '<Part Number>: GW1NR-LV9QN88PC6/I5',
    '<Setup Delay Model>:Slow 1.14V 85C C6/I5',
    '<Hold Delay Model>:Fast 1.26V 0C C6/I5'
)) {
    if (-not $report.Contains($required)) { throw "Baseline timing non riconosciuta: $required" }
}
$counts = @{}
foreach ($kind in @('Setup', 'Hold')) {
    $match = [regex]::Match($report, "<Numbers of $kind Violated Endpoints>:(\d+)")
    if (-not $match.Success) { throw "Riepilogo $kind mancante" }
    $counts[$kind] = [int]$match.Groups[1].Value
}
if ($counts.Hold -ne 0) { throw "Violazioni hold: $($counts.Hold)" }
if ($counts.Setup -gt 7) { throw "Setup: $($counts.Setup) endpoint, limite baseline 7" }

# Accepted setup families, inside the Gowin PSRAM IP only. Each one pins the
# exact node names, the clock pair and a slack floor. Nothing here matches
# psram_inst as a whole, so a user-RTL -> IP path still fails, and so does a
# known family that degrades past its floor.
#
# Both families are calibration logic of the hard IP: source and destination
# sit inside psram_inst and no user register is on the path. The design's own
# domains keep their margin - psram_clk_81 reports Fmax 85.5 MHz against an
# 80.998 MHz constraint - and the Fmax check below still enforces that.
$baselineFamilies = @(
    @{
        Name      = 'calibrazione IDES4'
        Floor     = -1.960
        From      = '^psram_inst/u_psram_top/u_psram_init/calib_0_s\d+/Q$'
        To        = '^psram_inst/u_psram_top/u_psram_wd/data_lane_gen\[0\]\.u_psram_lane/iserdes_gen\[[0-7]\]\.u_ides4/CALIB$'
        FromClock = 'psram_clk_81:[R]'
        ToClock   = 'mem_clk_162:[R]'
    },
    @{
        # Write-side DLL step calibration. Observed between -0.938 ns and
        # -1.170 ns on identical RTL across PlaceOption 0/1/2: the path moves
        # 232 ps on placement alone, so a clean report here was never margin.
        # The floor leaves headroom over the worst seen without going slack.
        Name      = 'passo DLL scrittura'
        Floor     = -1.400
        From      = '^psram_inst/u_psram_top/u_dll/CLKIN$'
        To        = '^psram_inst/u_psram_top/u_psram_wd/step_\d+_s\d+/(D|CE)$'
        FromClock = 'mem_clk_162:[R]'
        ToClock   = 'psram_clk_81:[R]'
    }
)

$section = ''
$seen = @{}
$negativeSetup = @()
$reachedEnd = $false
foreach ($line in $lines) {
    if ($line -match '^3\.1\.[1-4] (Setup|Hold|Recovery|Removal) Paths Table$') {
        $section = $Matches[1]
        $seen[$section] = 0
    } elseif ($line -match '^3\.2 Minimum Pulse Width Table$') {
        $section = 'PulseWidth'
        $seen[$section] = 0
    } elseif ($line -match '^3\.3 Timing Report By Analysis Type$') {
        $reachedEnd = $true
        break
    } elseif ($section -and $line -match '^\s+\d+\s+') {
        if ($section -eq 'PulseWidth') {
            if ($line -notmatch '^\s+\d+\s+(-?\d+\.\d+)\s+') { throw "Riga pulse width non riconosciuta: $line" }
            if ([double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) -lt 0) {
                throw "Violazione pulse width: $line"
            }
            $seen[$section]++
            continue
        }
        if ($line -notmatch '^\s+\d+\s+(-?\d+\.\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+') {
            throw "Riga timing non riconosciuta: $line"
        }
        $slack = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
        $from = $Matches[2]; $to = $Matches[3]
        $fromClock = $Matches[4]; $toClock = $Matches[5]
        $seen[$section]++
        if ($slack -lt 0) {
            $family = $null
            if ($section -eq 'Setup') {
                $family = $baselineFamilies | Where-Object {
                    $slack -ge $_.Floor -and $from -match $_.From -and $to -match $_.To -and
                    $fromClock -eq $_.FromClock -and $toClock -eq $_.ToClock
                } | Select-Object -First 1
            }
            if (-not $family) { throw "Violazione fuori baseline ($section): $line" }
            $negativeSetup += [pscustomobject]@{ Endpoint = $to; SlackNs = $slack; Family = $family.Name }
        }
    }
}
foreach ($kind in @('Setup', 'Hold', 'Recovery', 'Removal', 'PulseWidth')) {
    if (-not $seen.ContainsKey($kind) -or $seen[$kind] -eq 0) {
        throw "Tabella $kind mancante/vuota: impossibile verificare il timing"
    }
}
if (-not $reachedEnd) { throw 'Report timing troncato prima della fine delle tabelle' }
$endpoints = @($negativeSetup | Select-Object -ExpandProperty Endpoint -Unique)
if ($endpoints.Count -ne $counts.Setup) {
    throw "Copertura setup incompleta: tabella=$($endpoints.Count), riepilogo=$($counts.Setup)"
}

$frequencies = @{}
$memoryClock = [regex]::Match($report, '(?m)^\s+\d+\s+mem_clk_162\s+Base\s+(\d+\.\d+)\s+')
if (-not $memoryClock.Success -or
    [Math]::Abs([double]::Parse($memoryClock.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) - 6.173) -gt 0.0005) {
    throw 'Periodo mem_clk_162 diverso dalla baseline o clock mancante'
}
$expectedMHz = @{ xtal_27 = 27.0; lcd_clk_9 = 9.0; psram_clk_81 = 81.0 }
foreach ($clock in @('xtal_27', 'lcd_clk_9', 'psram_clk_81')) {
    $match = [regex]::Match($report, "(?m)^\s+\d+\s+$clock\s+(\d+\.\d+)\(MHz\)\s+(\d+\.\d+)\(MHz\)")
    if (-not $match.Success) { throw "Fmax mancante: $clock" }
    $constraint = [double]::Parse($match.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    $actual = [double]::Parse($match.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ([Math]::Abs($constraint - $expectedMHz[$clock]) -gt 0.005) { throw "Vincolo clock diverso dalla baseline: $clock ($constraint MHz)" }
    if ($actual -lt $constraint) { throw "Fmax insufficiente: $clock ($actual < $constraint MHz)" }
    $frequencies[$clock] = $actual
}
$worst = if ($negativeSetup.Count) { ($negativeSetup | Measure-Object SlackNs -Minimum).Minimum } else { 0 }
$families = ($negativeSetup | Group-Object Family | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
Write-Host "Timing OK: $($counts.Setup) setup di calibrazione ($families), worst $worst ns; hold/recovery/removal senza violazioni."
[pscustomobject]@{
    SetupCalibrationEndpoints = $counts.Setup
    WorstCalibrationSlackNs = $worst
    HoldViolations = $counts.Hold
    FmaxMHz = $frequencies
}
