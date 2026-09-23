$targets = @{
    "WD My Passport" = "WDMyPassport"
    "JMicron"        = "usb256"
}
$logFile = "$env:USERPROFILE\wsl_mount.log"

function Log($msg) {
    Add-Content -Path $logFile -Value "$(Get-Date -Format o) - $msg"
}

# Start WSL (idempotent if already running)
wsl -d Ubuntu -- true
Start-Sleep -Seconds 3

foreach ($name in $targets.Keys) {
    $disk = Get-Disk | Where-Object { $_.FriendlyName -like "*$name*" }
    if (-not $disk) {
        Log "Disk matching '$name' not found, skipping"
        continue
    }
    $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber 1
    $physicalPath = "\\.\PHYSICALDRIVE$($disk.Number)"
    $mountDir = "/mnt/$($targets[$name])"

    wsl --unmount $physicalPath 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # --bare: attach the disk without WSL's own auto-mount, so we control mounting explicitly and deterministically
    $attachResult = wsl --mount $physicalPath --bare 2>&1
    Start-Sleep -Seconds 2

    # Identify the attached partition device by exact byte size (avoids relying on disk-number/attach-order,
    # which shifts across reboots and reattaches). Parse lsblk JSON in PowerShell to avoid multi-layer shell escaping.
    $lsblkJson = wsl -d Ubuntu -- lsblk -b -J -o NAME,SIZE,TYPE
    $devName = $null
    try {
        $lsblkData = ($lsblkJson -join "`n") | ConvertFrom-Json
        $targetSize = [int64]$partition.Size
        foreach ($dev in $lsblkData.blockdevices) {
            if ($dev.children) {
                foreach ($child in $dev.children) {
                    if ($child.type -eq "part" -and [Math]::Abs([int64]$child.size - $targetSize) -lt 1048576) {
                        $devName = $child.name
                    }
                }
            }
        }
    } catch {
        Log "${name}: failed to parse lsblk JSON: $_"
    }

    if (-not $devName) {
        Log "${name}: attach result=$attachResult -- could not identify partition device by size, aborting"
        continue
    }

    wsl -d Ubuntu -- sudo mkdir -p $mountDir 2>&1 | Out-Null
    # 2026-08-23: clear any existing mount at this path BEFORE mounting. `wsl --unmount` above
    # detaches the DISK from the VM but leaves the Linux-side mount entry in place; mounting again
    # then STACKS a second filesystem on the same mountpoint -- a dead device underneath and the
    # live one on top. That stale lower layer is what puts processes into uninterruptible D-state.
    # Loop, because stacking can already be several layers deep.
    for ($u = 0; $u -lt 5; $u++) {
        $stillMounted = (wsl -d Ubuntu -- findmnt -rn -o SOURCE $mountDir 2>&1) -join ''
        if ([string]::IsNullOrWhiteSpace($stillMounted)) { break }
        wsl -d Ubuntu -- sudo umount -l $mountDir 2>&1 | Out-Null
    }
    $mountResult = wsl -d Ubuntu -- sudo mount "/dev/$devName" $mountDir 2>&1

    # 2026-08-23: `ls -A` is NOT proof of a mount. An unmounted placeholder directory can still
    # hold leftover stub subdirs, so an empty-listing test passes while nothing is actually mounted.
    # That false positive is exactly what let a detached WD Passport sit unnoticed. Verify that the
    # path is genuinely a mountpoint backed by the device we just mounted.
    $srcCheck = (wsl -d Ubuntu -- findmnt -rn -o SOURCE $mountDir 2>&1) -join ''
    if ($srcCheck -notlike "*/dev/$devName*") {
        Log "${name}: FAILED -- $mountDir is NOT a mountpoint of /dev/$devName (findmnt='$srcCheck') -- mount result: $mountResult"
    } else {
        Log "${name}: mounted /dev/$devName at $mountDir OK (verified via findmnt: $srcCheck)"
    }
}


# the server's local scratch HDD -- media lands here and Jellyfin reads it in place.

# Known WSL bug (regression since 2.5.7, unresolved as of 2.7.10): vmIdleTimeout=-1 does not reliably
# prevent the VM from being suspended, silently killing Docker/Jellyfin. Community workaround: keep a
# persistent WSL client process attached from the Windows side. This must run as its own dedicated
# Scheduled Task (WSL-KeepAlive) -- spawning it inline via Start-Process from this script gets killed
# when Task Scheduler tears down this script's own job object on completion.
schtasks /run /tn "WSL-KeepAlive" 2>&1 | Out-Null
Log "keep-alive tether (re)triggered via WSL-KeepAlive task"

# CRITICAL: Docker bind-mounts are a snapshot taken at container start. When WSL restarts (this script
# running again means it did), the host-side mounts above come back fine, but any ALREADY-RUNNING
# container's bind-mounts to those paths go stale/empty and are NOT live-refreshed by remounting the
# host path. Without this, Jellyfin silently serves an empty /media/* until someone notices and manually
# restarts it. Restart it here, every time, so its mounts are always fresh.
Start-Sleep -Seconds 2
$restartResult = wsl -d Ubuntu -- sudo docker restart jellyfin 2>&1
Start-Sleep -Seconds 3
# 2026-08-23: same false-positive class as above, one layer deeper. Docker binds the host
# DIRECTORY; if that directory was an unmounted placeholder at container start, the container sees
# the placeholder's leftover stub dirs and `ls -A` looks healthy. The reliable test is st_dev: a
# bind of a real disk sits on a different filesystem than the container's root, a bind of a
# placeholder shares it. Both media roots must differ from / before we call this OK.
function Test-JellyfinMediaLive {
    $devRoot  = (wsl -d Ubuntu -- sudo docker exec jellyfin stat -c '%d' / 2>&1) -join ''
    $devWd    = (wsl -d Ubuntu -- sudo docker exec jellyfin stat -c '%d' /media/wdpassport 2>&1) -join ''
    $devUsb   = (wsl -d Ubuntu -- sudo docker exec jellyfin stat -c '%d' /media/usb256 2>&1) -join ''
    $script:jfDetail = "root=$devRoot wdpassport=$devWd usb256=$devUsb"
    if (-not $devRoot -or -not $devWd -or -not $devUsb) { return $false }
    return (($devWd -ne $devRoot) -and ($devUsb -ne $devRoot))
}
if (-not (Test-JellyfinMediaLive)) {
    Log "jellyfin: restarted but media binds are STALE/EMPTY inside container ($script:jfDetail) -- retrying restart once"
    Start-Sleep -Seconds 2
    wsl -d Ubuntu -- sudo docker restart jellyfin 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    if (-not (Test-JellyfinMediaLive)) {
        Log "jellyfin: STILL STALE after retry ($script:jfDetail) -- needs manual investigation"
    } else {
        Log "jellyfin: OK after retry ($script:jfDetail)"
    }
} else {
    Log "jellyfin: restarted, media binds verified live ($script:jfDetail)"
}

# 2026-08-15: the Immich /external-photos block was removed from this script. The HP P900
# moved to the server and Immich reaches it over CIFS at /srv/hpp900, mounted from
# /etc/fstab inside WSL. Nothing here needs to touch it.
