# WSL keepalive tether + self-healing re-provision wrapper.
# Purpose (prevention, not watchdog): while this process holds an open WSL client,
# WSL will NOT idle-terminate the Ubuntu instance (works around the known
# vmIdleTimeout=-1 regression, unresolved as of WSL 2.7.10). If the instance dies
# anyway (wsl --shutdown, Windows update, crash), the tether call returns and we
# re-run wsl_start_and_mount.ps1 ONCE to bring the distro back with its raw disks
# attached and container bind-mounts refreshed, then re-attach the tether.
$log = '$env:USERPROFILE\wsl_keepalive.log'
function Log($m) { Add-Content -Path $log -Value "$(Get-Date -Format o) - $m" }

Log "wrapper started (pid $PID)"
while ($true) {
    $since = Get-Date
    Log "attaching tether"
    & wsl.exe -d Ubuntu -- sleep infinity
    $lived = (Get-Date) - $since
    Log ("tether exited after {0:n0}s (exit={1}) - WSL instance terminated" -f $lived.TotalSeconds, $LASTEXITCODE)

    # Backoff if the tether is dying immediately (WSL itself broken) so we don't spin.
    if ($lived.TotalSeconds -lt 60) { Start-Sleep -Seconds 60 } else { Start-Sleep -Seconds 8 }

    Log "re-provisioning via wsl_start_and_mount.ps1"
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\wsl_start_and_mount.ps1
        Log "re-provision script finished"
    } catch {
        Log "re-provision script error: $_"
    }
    Start-Sleep -Seconds 2
}
