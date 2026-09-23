# Nexus Laptop Agent -- small HTTP API exposing this machine's metrics and control
# points to the Nexus dashboard running on the server, over Tailscale.
# No new runtime dependency: pure PowerShell + System.Net.HttpListener.
$ErrorActionPreference = 'Stop'
Import-Module AudioDeviceCmdlets -ErrorAction SilentlyContinue

$TokenFile = "$env:USERPROFILE\nexus-agent-token.txt"
$Token = (Get-Content $TokenFile -Raw).Trim()
$Prefix = "http://<server-ip>:3391/"
$LogFile = "$env:USERPROFILE\nexus_agent.log"

function Log($msg) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o): $msg"
}

function Send-Json($response, $obj, $status = 200) {
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $response.StatusCode = $status
    $response.ContentType = "application/json"
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

$script:WslDiskCache = $null
$script:WslDiskCacheTime = [datetime]::MinValue

function Get-WslDisks {
    # 2026-08-15: /mnt/HPP900 was REMOVED from this df list. The HP P900 moved to
    # the server, and df exits non-zero if ANY listed path is missing -- which made the
    # whole call fail and blanked EVERY wsl disk card on the dashboard, not just the HP's.
    # Only ever list paths that are certain to exist here.
    # usb256 and the WD are ext4 inside WSL2 -- Windows cannot see
    # them, so Nexus gets their usage from here. Cached 60s so the 15s /metrics
    # poll never pays for a wsl.exe spawn, and guarded by --list --running so a
    # metrics call can never BOOT a shut-down WSL as a side effect.
    if ($script:WslDiskCache -ne $null -and ((Get-Date) - $script:WslDiskCacheTime).TotalSeconds -lt 60) {
        return $script:WslDiskCache
    }
    $disks = @()
    try {
        # wsl.exe defaults to UTF-16LE output; PowerShell 5.1 then sees NUL-interleaved
        # text and every -match silently fails. WSL_UTF8 fixes it; strip NULs anyway.
        $env:WSL_UTF8 = '1'
        $running = ((& wsl.exe --list --running --quiet) -join ' ') -replace "`0", ''
        if ($running -match 'Ubuntu') {
            $raw = & wsl.exe -d Ubuntu -e df -B1 -P /mnt/usb256 /mnt/WDMyPassport 2>$null
            foreach ($line in $raw) {
                $p = ((($line -replace "`0", '') -replace '\s+', ' ').Trim()).Split(' ')
                if ($p.Length -ge 6 -and $p[1] -match '^[0-9]+$') {
                    $disks += @{ filesystem = $p[0]; size = [long]$p[1]; used = [long]$p[2]; available = [long]$p[3]; percent = [int]($p[4] -replace '%',''); mount = $p[5] }
                }
            }
        }
    } catch {}
    $script:WslDiskCache = $disks
    $script:WslDiskCacheTime = Get-Date
    return $disks
}

function Get-Metrics {
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $os = Get-CimInstance Win32_OperatingSystem
    $memTotal = $os.TotalVisibleMemorySize * 1KB
    $memFree = $os.FreePhysicalMemory * 1KB
    $memUsedPct = [math]::Round((($memTotal - $memFree) / $memTotal) * 100)
    $disk = Get-PSDrive C
    $uptimeSec = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds

    $gpu = $null
    try {
        $gpuRaw = & nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null
        if ($gpuRaw) {
            $parts = $gpuRaw -split ',\s*'
            $gpu = @{ utilPct = [int]$parts[0]; tempC = [int]$parts[1]; memUsedMB = [int]$parts[2]; memTotalMB = [int]$parts[3] }
        }
    } catch {}

    return @{
        ok = $true
        cpu = @{ loadPercent = [int]($(if ($null -eq $cpu) { 0 } else { $cpu })) }
        memory = @{ total = $memTotal; free = $memFree; used = ($memTotal - $memFree); percent = $memUsedPct }
        disk = @{ filesystem = "C:"; size = ($disk.Used + $disk.Free); used = $disk.Used; available = $disk.Free; percent = [math]::Round(($disk.Used / ($disk.Used + $disk.Free)) * 100) }
        wslDisks = (Get-WslDisks)
        gpu = $gpu
        uptimeSeconds = $uptimeSec
        hostname = $env:COMPUTERNAME
    }
}

$DockerCache = $null
$DockerCacheTime = [DateTime]::MinValue
$DockerCacheTtlSec = 12

function Get-DockerContainers {
    # WSL2 also hosts the NFS server that the server's /srv/data + /srv/wd5tb depend
    # on -- every `wsl -d Ubuntu -- ...` invocation touches that same shared VM, and
    # frequent/heavy traffic here has been correlated with NFS export instability.
    # Cache + batch stats into ONE call instead of one-per-container to minimize load.
    if ($DockerCache -and ((Get-Date) - $DockerCacheTime).TotalSeconds -lt $DockerCacheTtlSec) {
        return $DockerCache
    }
    try {
        $raw = wsl -d Ubuntu -- docker ps -a --format '{{json .}}' 2>$null
        if (-not $raw) { return @() }
        $parsed = @($raw -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        $runningNames = @($parsed | Where-Object { $_.State -eq "running" } | ForEach-Object { $_.Names })

        $statsByName = @{}
        if ($runningNames.Count -gt 0) {
            $fmt = "{{.Name}}`t{{.CPUPerc}}`t{{.MemPerc}}`t{{.MemUsage}}"
            $statLines = wsl -d Ubuntu -- docker stats --no-stream --format $fmt @runningNames 2>$null
            foreach ($line in @($statLines -split "`n" | Where-Object { $_.Trim() })) {
                $sp = $line -split "`t"
                if ($sp.Count -ge 4) {
                    $statsByName[$sp[0]] = @{ cpuPct = [double]($sp[1] -replace '%',''); memPct = [double]($sp[2] -replace '%',''); memUsed = ($sp[3] -split '/')[0].Trim() }
                }
            }
        }

        $containers = @()
        foreach ($c in $parsed) {
            $running = $c.State -eq "running"
            $stats = if ($running -and $statsByName.ContainsKey($c.Names)) { $statsByName[$c.Names] } else { $null }
            $containers += @{ id = $c.ID; name = $c.Names; image = $c.Image; status = $c.Status; state = $c.State; ports = $c.Ports; running = $running; stats = $stats; machine = $env:AGENT_MACHINE_ID }
        }
        $script:DockerCache = $containers
        $script:DockerCacheTime = Get-Date
        return $containers
    } catch {
        Log "docker query failed: $_"
        return @()
    }
}

$DockerAllowlist = @("jellyfin", "immich_server", "immich_machine_learning", "immich_postgres", "immich_redis")
$GameProcessNames = @("BatmanAK", "Kena", "sekiro", "eden", "steam")

function Read-Body($request) {
    $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
    $body = $reader.ReadToEnd()
    $reader.Close()
    if (-not $body) { return @{} }
    try { return ($body | ConvertFrom-Json) } catch { return @{} }
}

function Invoke-DockerAction($name, $action) {
    if ($DockerAllowlist -notcontains $name) {
        return @{ ok = $false; error = "container $name not in allowlist" }
    }
    if ($action -notin @("start", "stop", "restart")) {
        return @{ ok = $false; error = "invalid action" }
    }
    $out = wsl -d Ubuntu -- docker $action $name 2>&1
    return @{ ok = $true; action = $action; name = $name; output = "$out" }
}

function Get-GameStreamStatus {
    $sunshine = Get-Service -Name SunshineService -ErrorAction SilentlyContinue
    $steamProc = Get-Process -Name steam -ErrorAction SilentlyContinue
    return @{
        ok = $true
        sunshine = ($sunshine -and $sunshine.Status -eq "Running")
        steam = [bool]$steamProc
        ready = ($sunshine -and $sunshine.Status -eq "Running") -and [bool]$steamProc
    }
}

function Start-GameStream {
    $sunshine = Get-Service -Name SunshineService -ErrorAction SilentlyContinue
    if ($sunshine -and $sunshine.Status -ne "Running") {
        Start-Service SunshineService
    }
    $steamProc = Get-Process -Name steam -ErrorAction SilentlyContinue
    if (-not $steamProc) {
        Start-Process "C:\Program Files (x86)\Steam\steam.exe"
    }
    Start-Sleep -Seconds 2
    return Get-GameStreamStatus
}

function Stop-GameStream {
    # Kill any actively running game + Steam first, then stop Sunshine so it's not
    # left idling/stressing the machine when nothing is actually being streamed.
    foreach ($name in $GameProcessNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    $sunshine = Get-Service -Name SunshineService -ErrorAction SilentlyContinue
    if ($sunshine -and $sunshine.Status -eq "Running") {
        Stop-Service SunshineService -Force
    }
    return Get-GameStreamStatus
}

function Get-DockerLogs($name) {
    if ($DockerAllowlist -notcontains $name) {
        return @{ ok = $false; error = "container $name not in allowlist" }
    }
    $out = wsl -d Ubuntu -- docker logs --tail 120 --timestamps $name 2>&1
    $lines = @($out -split "`n" | Where-Object { $_ })
    return @{ ok = $true; name = $name; lines = $lines }
}

$MediaPipeName  = "nexus-mpv"
$ShuffleScript  = "$env:USERPROFILE\nexus-shuffle-loop.ps1"
$ShuffleLock    = "$env:USERPROFILE\nexus-shuffle.lock"
$MpvPidFile     = "$env:USERPROFILE\mpv-current.pid"
$NdUrl = $env:ND_URL
$NdAuth = $env:ND_AUTH

function Send-MpvCommand($commandArray, $waitForResponse = $false) {
    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $MediaPipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(500)
        $writer = New-Object System.IO.StreamWriter($pipe)
        $writer.AutoFlush = $true
        $json = (@{ command = $commandArray } | ConvertTo-Json -Compress)
        $writer.WriteLine($json)
        $result = $null
        if ($waitForResponse) {
            $reader = New-Object System.IO.StreamReader($pipe)
            $line = $reader.ReadLine()
            if ($line) { $result = $line | ConvertFrom-Json }
        }
        $pipe.Close()
        return $result
    } catch {
        return $null
    }
}

# Kill a PID only after confirming it is still the process we think it is -- lock files go
# stale and Windows recycles PIDs, so an unverified kill can hit something unrelated.
function Stop-TrackedProcess($procId, $namePattern) {
    if (-not ($procId -match '^\d+$')) { return }
    $p = Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -match $namePattern) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}

function Stop-Music {
    if (Test-Path $ShuffleLock) {
        Stop-TrackedProcess (Get-Content $ShuffleLock -ErrorAction SilentlyContinue) 'powershell|pwsh'
        Remove-Item $ShuffleLock -ErrorAction SilentlyContinue
    }
    # Scoped to the tracked mpv -- a blanket Get-Process mpv kill also killed the 9AM
    # morning-music player, and vice versa.
    if (Test-Path $MpvPidFile) {
        Stop-TrackedProcess (Get-Content $MpvPidFile -ErrorAction SilentlyContinue) '^mpv$'
        Remove-Item $MpvPidFile -ErrorAction SilentlyContinue
    }
}

function Get-MediaStatus {
    $mpvProc = $null
    if (Test-Path $MpvPidFile) {
        $tracked = Get-Content $MpvPidFile -ErrorAction SilentlyContinue
        if ($tracked -match '^\d+$') {
            $mpvProc = Get-Process -Id ([int]$tracked) -ErrorAction SilentlyContinue |
                       Where-Object { $_.ProcessName -eq 'mpv' }
        }
    }
    if (-not $mpvProc) { $mpvProc = Get-Process mpv -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $mpvProc) {
        $idleVol = $null
        try { $volRaw = Get-AudioDevice -PlaybackVolume -ErrorAction SilentlyContinue; if ($volRaw) { $idleVol = [int][double]($volRaw -replace "%","") } } catch {}
        return @{ ok = $true; state = "idle"; songId = $null; paused = $false; timePos = $null; volume = $idleVol }
    }
    $songId = $null
    try {
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($mpvProc.Id)" -ErrorAction SilentlyContinue
        if ($cim -and $cim.CommandLine -match '[?&]id=([^&"\s]+)') { $songId = $Matches[1] }
    } catch {}
    $pauseResp = Send-MpvCommand @("get_property", "pause") $true
    $posResp   = Send-MpvCommand @("get_property", "time-pos") $true
    $paused = [bool]($pauseResp -and $pauseResp.data -eq $true)
    $timePos = $null
    if ($posResp -and $posResp.data -ne $null) { $timePos = [int]$posResp.data }
    $state = "playing"
    if ($paused) { $state = "paused" }
    $vol = $null
    try { $volRaw = Get-AudioDevice -PlaybackVolume -ErrorAction SilentlyContinue; if ($volRaw) { $vol = [int][double]($volRaw -replace "%","") } } catch {}
    return @{ ok = $true; state = $state; songId = $songId; paused = $paused; timePos = $timePos; volume = $vol }
}

function Ensure-SpeakerDefault {
    # Playback must go to the Stanmore, not whatever Windows currently defaults to
    # (built-in laptop speakers) -- same device-set step the 8:55AM script does.
    $dev = Get-AudioDevice -List -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$env:SPEAKER_NAME*" -and $_.Type -eq "Playback" }
    if (-not $dev) { return $false }
    if (-not $dev.Default) { Set-AudioDevice -InputObject $dev }
    return $true
}

function Start-Shuffle {
    if (-not (Ensure-SpeakerDefault)) { return @{ ok = $false; error = "Stanmore speaker not connected" } }
    Stop-Music
    Start-Sleep -Milliseconds 300
    Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ShuffleScript`"" -WindowStyle Hidden
    return @{ ok = $true }
}

function Start-SingleSong($songId) {
    if (-not (Ensure-SpeakerDefault)) { return @{ ok = $false; error = "Stanmore speaker not connected" } }
    Stop-Music
    Start-Sleep -Milliseconds 300
    $url = "$NdUrl/stream.view?$NdAuth&id=$songId"
    $p = Start-Process mpv -ArgumentList "--no-video --vo=null --no-terminal --really-quiet ""--input-ipc-server=\\.\pipe\$MediaPipeName"" ""$url""" -PassThru -WindowStyle Hidden
    $p.Id | Out-File -FilePath $MpvPidFile -Force
    return @{ ok = $true }
}

function Get-BtStatus {
    $dev = Get-AudioDevice -List -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$env:SPEAKER_NAME*" -and $_.Type -eq "Playback" }
    return @{ ok = $true; connected = [bool]$dev; default = [bool]($dev -and $dev.Default) }
}

function Start-BtConnect {
    # Fire-and-forget: reuse the same escalating reconnect script the 8:55AM task uses,
    # rather than duplicating its staged retry logic here. Caller polls /bt/status after.
    Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $env:USERPROFILE\bt-preconnect.ps1" -WindowStyle Hidden
    return @{ ok = $true; started = $true }
}

try {
# --- BOOT RACE GUARD (2026-08-17) ---
# 2026-08-16 02:04 this threw "The format of the specified network name is invalid":
# $Prefix binds to the Tailscale IP, and at boot+30s Tailscale had not yet brought
# the interface up, so the address did not exist to bind to. Wait for it. This only
# delays startup on a cold boot; a normal start finds the address immediately.
# On timeout we fall through and let the existing catch/exit 1 below hand off to the
# task RestartCount=5/PT1M. Do not replace this with a bind to 0.0.0.0 - that would
# expose :3391 on the LAN, which it deliberately is not today.
$BindIP = ([uri]$Prefix).Host
$BindDeadline = (Get-Date).AddMinutes(3)
while (-not (Get-NetIPAddress -IPAddress $BindIP -ErrorAction SilentlyContinue)) {
    if ((Get-Date) -gt $BindDeadline) {
        Log "STARTUP: $BindIP absent after 3 min; attempting bind anyway"
        break
    }
    Start-Sleep -Seconds 5
}
# --- end boot race guard ---
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    Log "Nexus laptop agent listening on $Prefix"
} catch {
    Log "STARTUP FAILED: $_"
    exit 1
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    try {
        $authHeader = $request.Headers["X-Nexus-Agent-Token"]
        if ($authHeader -ne $Token) {
            Send-Json $response @{ ok = $false; error = "unauthorized" } 401
            continue
        }

        $path = $request.Url.AbsolutePath
        $method = $request.HttpMethod

        if ($path -eq "/metrics" -and $method -eq "GET") {
            Send-Json $response (Get-Metrics)
        }
        elseif ($path -eq "/docker" -and $method -eq "GET") {
            Send-Json $response @{ ok = $true; containers = @(Get-DockerContainers) }
        }
        elseif ($path -eq "/docker/action" -and $method -eq "POST") {
            $body = Read-Body $request
            Send-Json $response (Invoke-DockerAction $body.name $body.action)
        }
        elseif ($path -eq "/gamestream/status" -and $method -eq "GET") {
            Send-Json $response (Get-GameStreamStatus)
        }
        elseif ($path -eq "/gamestream/start" -and $method -eq "POST") {
            Send-Json $response (Start-GameStream)
        }
        elseif ($path -eq "/gamestream/stop" -and $method -eq "DELETE") {
            Send-Json $response (Stop-GameStream)
        }
        elseif ($path -eq "/media/status" -and $method -eq "GET") {
            Send-Json $response (Get-MediaStatus)
        }
        elseif ($path -eq "/media/start" -and $method -eq "POST") {
            Send-Json $response (Start-Shuffle)
        }
        elseif ($path -eq "/media/stop" -and $method -eq "POST") {
            Stop-Music
            Send-Json $response @{ ok = $true }
        }
        elseif ($path -eq "/media/play_song" -and $method -eq "POST") {
            $body = Read-Body $request
            Send-Json $response (Start-SingleSong $body.songId)
        }
        elseif ($path -eq "/media/pause" -and $method -eq "POST") {
            Send-MpvCommand @("set_property", "pause", $true) | Out-Null
            Send-Json $response @{ ok = $true }
        }
        elseif ($path -eq "/media/resume" -and $method -eq "POST") {
            Send-MpvCommand @("set_property", "pause", $false) | Out-Null
            Send-Json $response @{ ok = $true }
        }
        elseif ($path -eq "/media/skip" -and $method -eq "POST") {
            Get-Process mpv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Send-Json $response @{ ok = $true }
        }
        elseif ($path -eq "/media/restart_song" -and $method -eq "POST") {
            Send-MpvCommand @("set_property", "time-pos", 0) | Out-Null
            Send-Json $response @{ ok = $true }
        }
        elseif ($path -eq "/media/volume" -and $method -eq "POST") {
            $body = Read-Body $request
            $vol = [int]$body.value
            Set-AudioDevice -PlaybackVolume ([math]::Max(0, [math]::Min(100, $vol)))
            Send-Json $response @{ ok = $true }
        }
        elseif ($path -eq "/docker/logs" -and $method -eq "GET") {
            $name = $request.QueryString["name"]
            Send-Json $response (Get-DockerLogs $name)
        }
        elseif ($path -eq "/bt/status" -and $method -eq "GET") {
            Send-Json $response (Get-BtStatus)
        }
        elseif ($path -eq "/bt/connect" -and $method -eq "POST") {
            Send-Json $response (Start-BtConnect)
        }
        elseif ($path -eq "/health" -and $method -eq "GET") {
            Send-Json $response @{ ok = $true; time = (Get-Date -Format o) }
        }
        else {
            Send-Json $response @{ ok = $false; error = "not found" } 404
        }
    } catch {
        Log "request error: $_"
        try { Send-Json $response @{ ok = $false; error = "$_" } 500 } catch {}
    }
}
