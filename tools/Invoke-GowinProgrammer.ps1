# Single entry point for programmer_cli. Exists because of two traps that cost
# a debugging session on 10 September 2026:
#
#   - programmer_cli is a frozen Python executable and reads PYTHONIOENCODING.
#     Its interpreter rejects the "utf-8:surrogateescape" form that many
#     automation environments export, and dies during interpreter start-up with
#     0xC0000409 before it ever touches the cable. Interactive shells rarely set
#     the variable, so the crash only shows up under automation.
#   - programmer_cli exits 0 even when it prints "Error: Verify Failed". An exit
#     code check alone therefore reports a successful, verified programming run
#     for a device that was never verified.
#
# Both are handled here so no caller has to remember them.
function Invoke-GowinProgrammer {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$ProgrammerPath
    )
    if (-not $ProgrammerPath) {
        $ProgrammerPath = 'C:\Program Files\Gowin\Gowin_V1.9.12.01_x64\IDE\bin\Gowin_V1.9.12.01_x64\Programmer\bin\programmer_cli.exe'
    }
    if (-not (Test-Path -LiteralPath $ProgrammerPath -PathType Leaf)) {
        throw "Gowin Programmer CLI non trovato: $ProgrammerPath"
    }

    $savedEncoding = $env:PYTHONIOENCODING
    $savedHome = $env:PYTHONHOME
    $savedPath = $env:PYTHONPATH
    try {
        $env:PYTHONIOENCODING = $null
        $env:PYTHONHOME = $null
        $env:PYTHONPATH = $null
        # Keep stderr: the verify failure is reported there, not on stdout.
        $output = & $ProgrammerPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $env:PYTHONIOENCODING = $savedEncoding
        $env:PYTHONHOME = $savedHome
        $env:PYTHONPATH = $savedPath
    }

    $text = ($output | ForEach-Object { [string]$_ })
    $text | ForEach-Object { Write-Host $_ }

    if ($exitCode -ne 0) {
        throw "Programmazione Gowin fallita con codice $exitCode"
    }
    # The exit code is not authoritative; the printed diagnostics are.
    $failures = @($text | Where-Object { $_ -match 'Verify\s+Failed|Error\s*:|Fatal Python error' })
    if ($failures.Count -gt 0) {
        throw ("programmer_cli ha riportato un errore pur uscendo con codice 0:`n  " +
               (($failures | Select-Object -First 5) -join "`n  "))
    }
    return $text
}
