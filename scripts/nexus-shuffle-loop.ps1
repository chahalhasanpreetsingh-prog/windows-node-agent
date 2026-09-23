# On-demand Navidrome shuffle loop for the Nexus dashboard's play button -- runs
# indefinitely (unlike the fixed 30-min morning script), one song at a time via mpv,
# controllable via mpv's JSON IPC over a named pipe. Windows port of the old
# the server navidrome-ondemand-play.sh loop.
#
# 2026-08-01 bugfixes:
#  - Added a fast-exit backoff. This is a `while ($true)` loop with no sleep on the
#    success path, so if mpv died instantly it spun forever at full CPU, hammering
#    Navidrome and spawning processes with no upper bound.
#  - mpv's PID is published to mpv-current.pid so the agent and the morning script can
#    stop exactly this player instead of blanket-killing every mpv on the box.
$LockFile   = "$env:USERPROFILE\nexus-shuffle.lock"
$LogFile    = "$env:USERPROFILE\nexus-shuffle.log"
$MpvPidFile = "$env:USERPROFILE\mpv-current.pid"
$NdUrl = $env:ND_URL
$Auth = $env:ND_AUTH   # Subsonic auth query string, e.g. u=...&t=...&s=...&v=1.16.1&c=agent
$PipeName   = "nexus-mpv"

function Log($msg) { Add-Content -Path $LogFile -Value "$(Get-Date -Format o): $msg" }

function Stop-TrackedProcess($procId, $namePattern) {
    if (-not ($procId -match '^\d+$')) { return }
    $p = Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -match $namePattern) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path $LockFile) {
    $oldPid = Get-Content $LockFile -ErrorAction SilentlyContinue
    # Verify the PID really is this script, not just any live process -- Windows recycles
    # PIDs, and a stale lock pointing at a reused PID would falsely abort the run.
    $alive = $null
    if ($oldPid -match '^\d+$') {
        $alive = Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -match 'nexus-shuffle-loop' }
    }
    if ($alive) {
        Log "Already running (PID $oldPid), exiting."
        exit 1
    }
    Remove-Item $LockFile -ErrorAction SilentlyContinue
}
$PID | Out-File -FilePath $LockFile -Force

$script:MyMpvPid = $null
try {
    $fastExits = 0
    while ($true) {
        $resp = Invoke-RestMethod -Uri "$NdUrl/getRandomSongs.view?$Auth&f=json&size=1" -TimeoutSec 8 -ErrorAction SilentlyContinue
        $song = $resp.'subsonic-response'.randomSongs.song | Select-Object -First 1
        if ($song) {
            Log "Playing - $($song.title)"
            $url = "$NdUrl/stream.view?$Auth&id=$($song.id)"
            $args = @(
                "--no-video", "--vo=null", "--no-terminal", "--really-quiet",
                "--input-ipc-server=\\.\pipe\$PipeName",
                $url
            )
            $started = Get-Date
            $p = Start-Process mpv -ArgumentList $args -PassThru -WindowStyle Hidden
            $script:MyMpvPid = $p.Id
            $p.Id | Out-File -FilePath $MpvPidFile -Force
            $p.WaitForExit()
            $script:MyMpvPid = $null
            Remove-Item $MpvPidFile -ErrorAction SilentlyContinue
            $played = ((Get-Date) - $started).TotalSeconds

            # An instant exit means playback is broken, not that the song finished.
            if ($played -lt 2) {
                $fastExits++
                Log "mpv exited after $([math]::Round($played,1))s (failure #$fastExits) - backing off 3s"
                Start-Sleep -Seconds 3
                if ($fastExits -ge 10) {
                    Log "ERROR: 10 consecutive instant mpv exits - playback is broken, exiting loop."
                    break
                }
            } else {
                $fastExits = 0
            }
        } else {
            Log "Failed to get song, retrying in 5s"
            Start-Sleep -Seconds 5
        }
    }
} finally {
    Remove-Item $LockFile -ErrorAction SilentlyContinue
    if ($script:MyMpvPid) { Stop-TrackedProcess $script:MyMpvPid '^mpv$' }
    Remove-Item $MpvPidFile -ErrorAction SilentlyContinue
}
