# Native processes without a shell: drain both streams, preserve diagnostics,
# enforce a wall-clock deadline, and always check the exit code. PS 5.1/7.
function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$LogPath,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 900
    )
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    # PowerShell Set/Push-Location does not update the native process cwd.
    $info.WorkingDirectory = (Get-Location).ProviderPath
    # Windows argv quoting (no cmd.exe/PowerShell interpretation).
    $info.Arguments = ($Arguments | ForEach-Object {
        '"' + [regex]::Replace([regex]::Replace($_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $writer = New-Object System.IO.StreamWriter($LogPath, $false)
    $writer.AutoFlush = $true
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw "Avvio fallito: $FilePath" }
        $streams = @($process.StandardOutput, $process.StandardError)
        $pending = @($streams[0].ReadLineAsync(), $streams[1].ReadLineAsync())
        while ($null -ne $pending[0] -or $null -ne $pending[1] -or -not $process.HasExited) {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw "TIMEOUT reale dopo $TimeoutSeconds s: $FilePath (log: $LogPath)"
            }
            $received = $false
            for ($i = 0; $i -lt 2; $i++) {
                if ($null -ne $pending[$i] -and $pending[$i].IsCompleted) {
                    $line = $pending[$i].GetAwaiter().GetResult()
                    if ($null -eq $line) { $pending[$i] = $null }
                    else {
                        $writer.WriteLine($line)
                        Write-Host $line
                        $pending[$i] = $streams[$i].ReadLineAsync()
                    }
                    $received = $true
                }
            }
            if (-not $received) { Start-Sleep -Milliseconds 50 }
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "$FilePath terminato con codice $($process.ExitCode) (log: $LogPath)"
        }
    } catch {
        $writer.WriteLine("FAIL: $($_.Exception.Message)")
        throw
    } finally {
        if ($started -and -not $process.HasExited) {
            # .NET in PS 7 can stop compiler/EDA children too. On PS 5.1
            # Kill() guarantees termination of the directly launched process.
            if ($process.PSObject.Methods['Kill'].OverloadDefinitions -match 'bool') {
                $process.Kill($true)
            } else {
                $process.Kill()
            }
            $process.WaitForExit()
        }
        $process.Dispose()
        $writer.Dispose()
        $watch.Stop()
    }
}
