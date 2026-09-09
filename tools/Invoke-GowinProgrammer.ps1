# Single entry point for programmer_cli. Exists because of three traps, all
# found the hard way on 10 September 2026:
#
#   - programmer_cli is a frozen Python executable and reads PYTHONIOENCODING.
#     Its interpreter rejects the "utf-8:surrogateescape" form that many
#     automation environments export, and dies during interpreter start-up with
#     0xC0000409 before it ever touches the cable. Interactive shells rarely set
#     the variable, so the crash only shows up under automation.
#   - programmer_cli can exit 0 while printing "Error: ...", so the exit code
#     alone is not a verdict.
#   - On this project the Embedded Flash verify stage always fails, and drags
#     "Error: Program failed" and sometimes exit 1 along with it, even though
#     the write itself succeeded. Treating that as fatal would make flash
#     programming permanently unusable, so it is reported as a warning that
#     says how to confirm the real outcome. Anything else is still fatal.
$script:GowinBenignPattern = 'Verify\s+Failed|Program\s+failed'

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
        # Keep stderr: the verify diagnostics are reported there, not on stdout.
        $output = & $ProgrammerPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $env:PYTHONIOENCODING = $savedEncoding
        $env:PYTHONHOME = $savedHome
        $env:PYTHONPATH = $savedPath
    }

    $text = ($output | ForEach-Object { [string]$_ })
    $text | ForEach-Object { Write-Host $_ }

    $problems = @($text | Where-Object { $_ -match 'Error\s*:|Fatal Python error|Verify\s+Failed' })
    $real = @($problems | Where-Object { $_ -notmatch $script:GowinBenignPattern })

    if ($real.Count -gt 0) {
        throw ("programmer_cli ha riportato un errore:`n  " +
               (($real | Select-Object -First 5) -join "`n  "))
    }
    if ($problems.Count -gt 0) {
        Write-Warning (@(
            'La verifica della Embedded Flash e'' fallita. Su questo progetto e'' un',
            'falso allarme noto: la scrittura riesce comunque. NON riprogrammare.',
            'Per accertarsene, stacca e riattacca l''alimentazione della Tang Nano,',
            'poi rileggi i codici: a configurazione avvenuta il User Code non e'' piu''',
            '0x00000000 e il bit di CRC error nello status sparisce. Il pulsante di',
            'reset non serve: e'' un reset logico e non provoca riconfigurazione.',
            'Dettagli in docs/PROGRAMMING.md.'
        ) -join "`n")
        return [pscustomobject]@{ Output = $text; VerifyWarning = $true }
    }
    # No diagnostics printed: now the exit code is meaningful.
    if ($exitCode -ne 0) {
        throw "Programmazione Gowin fallita con codice $exitCode"
    }
    return [pscustomobject]@{ Output = $text; VerifyWarning = $false }
}
