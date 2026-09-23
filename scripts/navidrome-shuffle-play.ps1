# 9 AM morning music -- 30 minutes on the BT speaker.
# bt-preconnect.ps1 runs at 8:55 AM so the sink should already be ready.
#
# 2026-08-01 bugfixes:
#  - mpv is now launched via Start-Process -PassThru and tracked by PID. The old
#    `Get-Process mpv | Stop-Process` in finally killed EVERY mpv on the box, including
#    the Nexus dashboard's on-demand shuffle loop (and did so even on the early
#    "BT sink not ready" exit). Kills are now scoped to this script's own mpv.
#  - Added a fast-exit backoff. The play loop had no sleep on the success path, so if
#    mpv died instantly (sink vanished, stream 404) it spun as fast as the CPU allowed,
#    hammering Navidrome and spawning processes for the rest of the 30 minutes.
#  - Takes deliberate ownership of the shared \\.\pipe\nexus-mpv IPC pipe by stopping any
#    other player first, so two mpv instances can never contend for the same pipe name.
Import-Module AudioDeviceCmdlets

$LogFile = "$env:USERPROFILE\navidrome-play.log"
$LockFile = "$env:USERPROFILE\navidrome-shuffle.lock"
$MpvPidFile = "$env:USERPROFILE\mpv-current.pid"
$ShuffleLock = "$env:USERPROFILE\nexus-shuffle.lock"
$MpvExe = "mpv"
$NdUrl = $env:ND_URL
$Auth = $env:ND_AUTH   # Subsonic auth query string, e.g. u=...&t=...&s=...&v=1.16.1&c=agent

function Log($msg) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o): $msg"
}

# Kill a PID only after confirming it is still the process we think it is -- lock files
# go stale and Windows recycles PIDs, so an unverified kill can hit something unrelated.
function Stop-TrackedProcess($procId, $namePattern) {
    if (-not ($procId -match '^\d+$')) { return }
    $p = Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -match $namePattern) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}

# Only one music player may own the speaker and the nexus-mpv pipe at a time.
function Stop-OtherPlayers {
    if (Test-Path $ShuffleLock) {
        Stop-TrackedProcess (Get-Content $ShuffleLock -ErrorAction SilentlyContinue) 'powershell|pwsh'
        Remove-Item $ShuffleLock -ErrorAction SilentlyContinue
    }
    if (Test-Path $MpvPidFile) {
        Stop-TrackedProcess (Get-Content $MpvPidFile -ErrorAction SilentlyContinue) '^mpv$'
        Remove-Item $MpvPidFile -ErrorAction SilentlyContinue
    }
}

# Prevent overlapping runs
if (Test-Path $LockFile) {
    $oldPid = Get-Content $LockFile -ErrorAction SilentlyContinue
    # Verify the PID really is this script, not just any live process -- Windows recycles
    # PIDs, and a stale lock pointing at a reused PID would falsely abort the run.
    $alive = $null
    if ($oldPid -match '^\d+$') {
        $alive = Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -match 'navidrome-shuffle-play' }
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
    function Get-SpeakerDevice {
        Get-AudioDevice -List | Where-Object { $_.Name -like "*$env:SPEAKER_NAME*" -and $_.Type -eq "Playback" }
    }

    # The default output device is set ONCE at startup, but the A2DP link can drop at any
    # point during the 30 minutes. When it does, Windows silently moves playback to the
    # internal Realtek speakers and every following track plays inaudibly while this log
    # still reads "Playing - <song>". That is exactly how a morning looks perfect in the
    # log and is silent in the room (observed 2026-08-03 09:41 and 2026-08-04 09:32).
    # So: re-verify before every track, give the sink a short window to come back, and
    # then fail loudly rather than playing to the wrong device.
    function Confirm-SpeakerOutput([int]$WaitSeconds = 90) {
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        $warned = $false
        while ($true) {
            $dev = Get-SpeakerDevice
            if ($dev) {
                if (-not $dev.Default) {
                    Log "Speaker was no longer the default output - restoring it."
                    Set-AudioDevice -InputObject $dev
                    Set-AudioDevice -PlaybackVolume 85
                }
                if ($warned) { Log "BT sink returned - resuming playback to the speaker." }
                return $true
            }
            if ((Get-Date) -ge $deadline) { return $false }
            if (-not $warned) {
                Log "WARNING: BT sink vanished mid-session - waiting up to ${WaitSeconds}s for it to return."
                $warned = $true
            }
            Start-Sleep -Seconds 5
        }
    }

    Log "Waiting for BT sink..."
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
        if (Get-SpeakerDevice) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }

    if (-not $ready) {
        Log "ERROR: BT sink not available. Is the speaker on? Aborting."
        exit 1
    }

    Log "BT sink ready. Setting as default audio device..."
    $dev = Get-SpeakerDevice
    Set-AudioDevice -InputObject $dev
    Set-AudioDevice -PlaybackVolume 85

    # Take ownership: stop any dashboard-started playback so we alone hold the IPC pipe.
    Stop-OtherPlayers

    $endTime = (Get-Date).AddMinutes(30)

    # Returns how many seconds mpv actually ran, so the caller can detect instant failures.
    function Play-Stream($songId, $maxSeconds) {
        $url = "$NdUrl/stream.view?$Auth&id=$songId"
        $args = @(
            "--no-video", "--vo=null", "--no-terminal", "--really-quiet",
            "--input-ipc-server=\\.\pipe\nexus-mpv",
            "--length=$maxSeconds",
            $url
        )
        $started = Get-Date
        $p = Start-Process $MpvExe -ArgumentList $args -PassThru -WindowStyle Hidden
        $script:MyMpvPid = $p.Id
        $p.Id | Out-File -FilePath $MpvPidFile -Force
        $p.WaitForExit()
        $script:MyMpvPid = $null
        Remove-Item $MpvPidFile -ErrorAction SilentlyContinue
        return ((Get-Date) - $started).TotalSeconds
    }

    # Always open with Aarti (Aqeedat-E-Sartaaj) by Satinder Sartaaj.
    # Retry the lookup: an empty/rescanning library returns no results, and a one-shot
    # search here would drop the opener for the whole morning (as it did on 2026-07-15).
    function Find-Opener {
        try {
            $searchResult = Invoke-RestMethod -Uri "$NdUrl/search3.view?$Auth&f=json&query=Aarti&songCount=20"
            $songs = $searchResult.'subsonic-response'.searchResult3.song
            return $songs | Where-Object { $_.artist -eq "Satinder Sartaaj" -and $_.title -like "Aarti*" } | Select-Object -First 1
        } catch {
            Log "Opener search failed: $($_.Exception.Message)"
            return $null
        }
    }

    $openerDeadline = (Get-Date).AddMinutes(5)
    $opener = $null
    while (-not $opener -and (Get-Date) -lt $openerDeadline) {
        $opener = Find-Opener
        if (-not $opener) {
            Log "Opener not found yet (library may be empty/rescanning), retrying in 5s"
            Start-Sleep -Seconds 5
        }
    }

    if ($opener) {
        if (-not (Confirm-SpeakerOutput)) {
            Log "ERROR: BT sink gone before the opener and did not return - aborting rather than playing to internal speakers."
            exit 1
        }
        Log "Playing opener - Aarti (Aqeedat-E-Sartaaj)"
        $remaining = [int](($endTime - (Get-Date)).TotalSeconds)
        if ($remaining -gt 1066) { $remaining = 1066 }
        $null = Play-Stream $opener.id $remaining
    } else {
        Log "WARNING: Aarti opener not found after 5 min of retries, skipping to shuffle."
    }

    $fastExits = 0
    while ((Get-Date) -lt $endTime) {
        $resp = Invoke-RestMethod -Uri "$NdUrl/getRandomSongs.view?$Auth&f=json&size=1"
        $song = $resp.'subsonic-response'.randomSongs.song | Select-Object -First 1

        if ($song) {
            if (-not (Confirm-SpeakerOutput)) {
                Log "ERROR: BT sink gone and did not return within 90s - stopping (refusing to play to internal speakers)."
                break
            }
            $remaining = [int](($endTime - (Get-Date)).TotalSeconds)
            if ($remaining -le 0) { break }
            Log "Playing - $($song.title) (${remaining}s remaining)"
            $played = Play-Stream $song.id $remaining

            # mpv returning almost immediately means playback is broken, not that the song
            # ended. Back off so a persistent failure cannot become a tight spawn loop.
            if ($played -lt 2) {
                $fastExits++
                Log "mpv exited after $([math]::Round($played,1))s (failure #$fastExits) - backing off 3s"
                Start-Sleep -Seconds 3
                if ($fastExits -ge 10) {
                    Log "ERROR: 10 consecutive instant mpv exits - playback is broken, aborting."
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

    Log "30 minutes done, stopping."
} finally {
    Remove-Item $LockFile -ErrorAction SilentlyContinue
    # Scoped to our own mpv -- never a blanket Get-Process mpv kill.
    if ($script:MyMpvPid) { Stop-TrackedProcess $script:MyMpvPid '^mpv$' }
    Remove-Item $MpvPidFile -ErrorAction SilentlyContinue
}
