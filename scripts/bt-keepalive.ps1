# Keeps the $env:SPEAKER_NAME II BT speaker awake / A2DP link open when nothing is actively
# playing, so it doesn't idle-sleep and drop the connection overnight or during long
# gaps -- matches the old the server stanmore-connect.sh keepalive mechanism
# (silent audio ping every ~3 min while connected), ported to Windows.
#
# 2026-07-10: now also RE-connects. Old version only pinged while connected, so one
# overnight drop meant the speaker stayed dead until 8:55 (log showed "skipping" from
# 00:05 to morning, 3 days straight). New behaviour when disconnected: after 2
# consecutive misses (~6 min), launch bt-preconnect.ps1 (detached), at most once per
# 30 min, and NEVER while a Moonlight/Sunshine stream is active (radio restart would
# drop stream-session BT devices).
Import-Module AudioDeviceCmdlets

$LogFile = "$env:USERPROFILE\bt_keepalive.log"
$SilentWav = "$env:USERPROFILE\keepalive_tone.wav"
$StateFile = "$env:USERPROFILE\bt_keepalive_state.txt"

function Log($msg) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o): $msg"
}

function Get-SpeakerDevice {
    Get-AudioDevice -List | Where-Object { $_.Name -like "*$env:SPEAKER_NAME*" -and $_.Type -eq "Playback" }
}

if (-not (Test-Path $SilentWav)) {
    $sampleRate = 44100
    $durationMs = 300
    $numSamples = [int]($sampleRate * $durationMs / 1000)
    $dataSize = $numSamples * 2
    $byteRate = $sampleRate * 2
    $fs = [System.IO.File]::Create($SilentWav)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("RIFF"))
    $bw.Write([int32](36 + $dataSize))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("WAVE"))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("fmt "))
    $bw.Write([int32]16)
    $bw.Write([int16]1)
    $bw.Write([int16]1)
    $bw.Write([int32]$sampleRate)
    $bw.Write([int32]$byteRate)
    $bw.Write([int16]2)
    $bw.Write([int16]16)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("data"))
    $bw.Write([int32]$dataSize)
    # Very low-amplitude tone rather than true digital silence -- some A2DP stacks
    # treat an all-zero stream as "no audio" and still let the link idle out.
    for ($i = 0; $i -lt $numSamples; $i++) {
        $sample = [int16]([Math]::Sin(2 * [Math]::PI * 20 * $i / $sampleRate) * 50)
        $bw.Write($sample)
    }
    $bw.Close()
    $fs.Close()
    Log "generated keepalive tone WAV"
}

$dev = Get-SpeakerDevice
if ($dev) {
    if (-not $dev.Default) {
        Set-AudioDevice -InputObject $dev
    }
    try {
        $player = New-Object System.Media.SoundPlayer $SilentWav
        $player.PlaySync()
        Log "keepalive ping sent (speaker connected)"
    } catch {
        Log "keepalive ping failed: $_"
    }
    Set-Content -Path $StateFile -Value "misses=0`nlastAttempt=0`nattempts=0"
    exit 0
}

# --- Disconnected: escalate to auto-reconnect ---
$misses = 0; $lastAttempt = 0; $attempts = 0
if (Test-Path $StateFile) {
    foreach ($line in Get-Content $StateFile) {
        if ($line -match '^misses=(\d+)') { $misses = [int]$Matches[1] }
        if ($line -match '^lastAttempt=(\d+)') { $lastAttempt = [long]$Matches[1] }
        if ($line -match '^attempts=(\d+)') { $attempts = [int]$Matches[1] }
    }
}

# Escalating backoff. A flat 30-min cooldown meant that once the speaker stopped
# answering entirely, this ran the FULL bt-preconnect ladder -- 3 radio restarts plus a
# PnP node cycle, ~4.5 minutes of radio churn -- every half hour, all night, with zero
# chance of success (2026-08-04 22:35 -> 2026-08-05 03:12, 10 consecutive failures).
# That is pointless wear and it risks leaving the radio mid-restart at 08:55 when the
# preconnect that actually matters fires. Back off instead: 30m, 30m, 30m, 1h, 2h, cap 3h.
$cooldown = switch ($attempts) { 0 {1800} 1 {1800} 2 {1800} 3 {3600} 4 {7200} default {10800} }
$misses++
$now = [long][DateTimeOffset]::Now.ToUnixTimeSeconds()

$streamActive = [bool](Get-NetTCPConnection -LocalPort 47984,47989,48010 -State Established -ErrorAction SilentlyContinue)
if ($streamActive) {
    Log "speaker not connected (miss $misses) but game stream ACTIVE - deferring auto-reconnect."
    Set-Content -Path $StateFile -Value "misses=$misses`nlastAttempt=$lastAttempt"
    exit 0
}

if ($misses -ge 2 -and ($now - $lastAttempt) -ge $cooldown) {
    $attempts++
    Log "speaker not connected (miss $misses, attempt #$attempts, last reconnect attempt $([int](($now-$lastAttempt)/60)) min ago) - launching bt-preconnect auto-reconnect."
    Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $env:USERPROFILE\bt-preconnect.ps1" -WindowStyle Hidden
    Set-Content -Path $StateFile -Value "misses=$misses`nlastAttempt=$now`nattempts=$attempts"
} else {
    Log "speaker not connected (miss $misses) - waiting ($([int]($cooldown/60))min cooldown after $attempts failed attempt(s), or first miss)."
    Set-Content -Path $StateFile -Value "misses=$misses`nlastAttempt=$lastAttempt`nattempts=$attempts"
}
