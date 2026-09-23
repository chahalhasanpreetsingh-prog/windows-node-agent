Start-Sleep -Seconds 30

$pipeName = "MTTVirtualDisplayPipe"
$cmd = 'SETGPU "NVIDIA GeForce RTX 3050 Laptop GPU"'
$maxAttempts = 6
$success = $false

for ($i = 0; $i -lt $maxAttempts; $i++) {
    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(5000)
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmd + "`0")
        $pipe.Write($bytes, 0, $bytes.Length)
        $pipe.Flush()
        Start-Sleep -Milliseconds 500
        $pipe.Close()
        $success = $true
        break
    } catch {
        Start-Sleep -Seconds 10
    }
}

if ($success) {
    Restart-Service -Name SunshineService -Force -ErrorAction SilentlyContinue
}

$logLine = "$(Get-Date -Format o) - SETGPU sent: $success"
Add-Content -Path "$env:USERPROFILE\vdd_boot_fix.log" -Value $logLine
