# Runs at 8:55 AM -- ensures the BT speaker ($env:SPEAKER_NAME II) is connected and set as
# default playback device, so it's ready before the 9 AM music script.
# 2026-07-10: Stage 2 now retries the radio-restart cycle up to 3 times. Evidence from
# 07-08/09/10 mornings: a single restart cycle often fails, but a 2nd-3rd cycle lands.
# 2026-07-27: Stage 3 added -- cycles the SPEAKER's own MEDIA nodes to force A2DP
# re-enumeration. Fixes the 07-17/07-24/07-27 failure that Stage 2 provably cannot.
# 2026-08-05: TWO changes, from a night where the speaker was unreachable for ~5h (BT
# stack reported connected=0, lastSeen 22:56) across TEN full ladders -- 30 radio
# restarts and 10 MEDIA-node cycles, every single one failing:
#   Stage 1.5 -- an active inquiry scan. Non-destructive (~8s, touches no PnP state), so
#     it belongs before the radio restarts. NOTE: this is NOT what recovered 08-05; it is
#     here as a cheap first probe only. Do not credit it with more than that.
#   Stage 4 -- cycle the PARENT Bluetooth device node. This IS what recovered 08-05.
#     Stage 3 cycles only the MEDIA *children*; the wedged node was their parent
#     (BTHENUM\DEV_<mac>). After cycling the parent, the very next Stage 3 succeeded in
#     22s having failed 10 times in a row immediately before.
Import-Module AudioDeviceCmdlets

$LogFile = "$env:USERPROFILE\navidrome-play.log"
function Log($msg) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o): $msg"
}

function Get-SpeakerDevice {
    Get-AudioDevice -List | Where-Object { $_.Name -like "*$env:SPEAKER_NAME*" -and $_.Type -eq "Playback" }
}

function Sink-Ready {
    $dev = Get-SpeakerDevice
    return [bool]$dev
}

# An active inquiry makes the local stack go out and look for devices instead of waiting
# to be found. A paired-but-idle speaker that has stopped answering passive reconnects
# frequently re-establishes the moment it is inquired for.
function Invoke-BtInquiry {
    try {
        if (-not ("BTQ" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BTQ {
  [StructLayout(LayoutKind.Sequential)]
  public struct SYSTEMTIME { public ushort wYear,wMonth,wDayOfWeek,wDay,wHour,wMinute,wSecond,wMilliseconds; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DEVINFO {
    public uint dwSize; public ulong Address; public uint ulClassofDevice;
    public int fConnected; public int fRemembered; public int fAuthenticated;
    public SYSTEMTIME stLastSeen; public SYSTEMTIME stLastUsed;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=248)] public string szName;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct SEARCH {
    public uint dwSize; public int fReturnAuthenticated; public int fReturnRemembered;
    public int fReturnUnknown; public int fReturnConnected; public int fIssueInquiry;
    public byte cTimeoutMultiplier; public IntPtr hRadio;
  }
  [DllImport("bthprops.cpl", SetLastError=true)]
  public static extern IntPtr BluetoothFindFirstDevice(ref SEARCH p, ref DEVINFO i);
  [DllImport("bthprops.cpl", SetLastError=true)]
  public static extern bool BluetoothFindDeviceClose(IntPtr h);
}
"@ -ErrorAction Stop
        }
        $sp = New-Object BTQ+SEARCH
        $sp.dwSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'BTQ+SEARCH')
        $sp.fReturnAuthenticated = 1; $sp.fReturnRemembered = 1; $sp.fReturnUnknown = 1
        $sp.fReturnConnected = 1; $sp.fIssueInquiry = 1; $sp.cTimeoutMultiplier = 6
        $sp.hRadio = [IntPtr]::Zero
        $di = New-Object BTQ+DEVINFO
        $di.dwSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'BTQ+DEVINFO')
        $h = [BTQ]::BluetoothFindFirstDevice([ref]$sp, [ref]$di)
        if ($h -ne [IntPtr]::Zero) { [void][BTQ]::BluetoothFindDeviceClose($h) }
        return $true
    } catch {
        Log "Stage 1.5: inquiry scan could not run: $($_.Exception.Message)"
        return $false
    }
}

if (Sink-Ready) {
    $dev = Get-SpeakerDevice
    if (-not $dev.Default) {
        Set-AudioDevice -InputObject $dev
    }
    Log "BT sink already present, set as default. Nothing more to do."
    exit 0
}

Log "Stage 1: BT speaker not currently visible as an audio device. Waiting up to 40s (Windows auto-reconnects paired devices in range)."
$deadline = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $deadline) {
    if (Sink-Ready) {
        $dev = Get-SpeakerDevice
        Set-AudioDevice -InputObject $dev
        Log "Stage 1 success."
        exit 0
    }
    Start-Sleep -Seconds 2
}

Log "Stage 1.5: running an active Bluetooth inquiry scan (non-destructive) to prompt a reconnect."
[void](Invoke-BtInquiry)
$deadline = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $deadline) {
    if (Sink-Ready) {
        $dev = Get-SpeakerDevice
        Set-AudioDevice -InputObject $dev
        Log "Stage 1.5 success: inquiry scan brought the speaker back, no radio restart needed."
        exit 0
    }
    Start-Sleep -Seconds 2
}

$btRadio = Get-PnpDevice | Where-Object { $_.FriendlyName -like "*Wireless Bluetooth*" }
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Log "Stage 2 (attempt $attempt/3): restarting Bluetooth radio (Intel Wireless Bluetooth) to force a reconnect attempt."
    if ($btRadio) {
        Disable-PnpDevice -InstanceId $btRadio.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Enable-PnpDevice -InstanceId $btRadio.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 5

    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if (Sink-Ready) {
            $dev = Get-SpeakerDevice
            Set-AudioDevice -InputObject $dev
            Log "Stage 2 success (attempt $attempt)."
            exit 0
        }
        Start-Sleep -Seconds 2
    }
}

# Stage 3 (added 2026-07-27) -- the escalation Stage 2 was always missing.
# Failure signature this fixes (seen 07-17, 07-24, and live on 07-27): the Bluetooth and
# MEDIA nodes all report "OK", but the "Speakers ($env:SPEAKER_NAME II)" AudioEndpoint sits at status
# "Unknown" and never enters Get-AudioDevice -List. The link is up as AVRCP-only; the RADIO
# is not the fault, which is why no number of Stage 2 cycles can ever fix it. Cycling the
# speaker's own MEDIA nodes forces the A2DP render endpoint to re-enumerate -- took ~5s when
# performed by hand on 2026-07-27. Nodes are looked up by name/class, not by hardcoded
# InstanceId, so this survives a re-pair.
$mediaNodes = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*$env:SPEAKER_NAME*" -and $_.Class -eq "MEDIA" }

if (-not $mediaNodes) {
    Log "Stage 3: no $env:SPEAKER_NAME MEDIA nodes present -- speaker is not linked at all, nothing to cycle."
} else {
    $names = ($mediaNodes | ForEach-Object { $_.FriendlyName }) -join ", "
    Log "Stage 3: cycling $env:SPEAKER_NAME MEDIA PnP nodes to force A2DP re-enumeration ($names)."
    $mediaNodes | ForEach-Object {
        Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 8
    $mediaNodes | ForEach-Object {
        Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Sink-Ready) {
            $dev = Get-SpeakerDevice
            Set-AudioDevice -InputObject $dev
            Log "Stage 3 success: A2DP endpoint re-enumerated, speaker set as default."
            exit 0
        }
        Start-Sleep -Seconds 2
    }
    Log "Stage 3 failed: MEDIA nodes cycled but no A2DP render endpoint appeared within 60s."
}

# Stage 4 (added 2026-08-05) -- cycle the PARENT Bluetooth device node.
# Stage 3 cycles the speaker's MEDIA child nodes. On 2026-08-05 those children all
# reported "OK" while the AudioEndpoint sat at CM_PROB_PHANTOM and the whole device
# reported connected=0 for five hours -- the *parent* enumeration was wedged, so
# re-enumerating the children under it could never help. Cycling the parent cleared it,
# and the next MEDIA-node cycle then succeeded within 22 seconds.
$parent = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like "BTHENUM\DEV_54B7E5B995EE*" -and $_.Class -eq "Bluetooth" }

if (-not $parent) {
    Log "Stage 4: parent Bluetooth node for the speaker not found -- nothing to cycle."
} else {
    Log "Stage 4: cycling the PARENT Bluetooth device node ($($parent.InstanceId))."
    $parent | ForEach-Object { Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 8
    $parent | ForEach-Object { Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }

    # The parent cycle re-establishes the link; the A2DP endpoint may then need one more
    # MEDIA-node cycle on top (that is exactly the 08-05 sequence), so re-run Stage 3's
    # cycle once after it rather than waiting for the next scheduled ladder.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Sink-Ready) {
            $dev = Get-SpeakerDevice
            Set-AudioDevice -InputObject $dev
            Log "Stage 4 success: parent node cycle restored the speaker."
            exit 0
        }
        Start-Sleep -Seconds 2
    }

    $mediaNodes2 = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -like "*$env:SPEAKER_NAME*" -and $_.Class -eq "MEDIA" }
    if ($mediaNodes2) {
        Log "Stage 4b: parent cycled but no endpoint yet -- re-cycling MEDIA nodes on top."
        $mediaNodes2 | ForEach-Object { Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 8
        $mediaNodes2 | ForEach-Object { Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            if (Sink-Ready) {
                $dev = Get-SpeakerDevice
                Set-AudioDevice -InputObject $dev
                Log "Stage 4b success: speaker restored after parent + MEDIA cycle."
                exit 0
            }
            Start-Sleep -Seconds 2
        }
    }
    Log "Stage 4 failed: parent node cycled (and MEDIA re-cycled) but no A2DP endpoint appeared."
}

Log "WARNING: BT sink not ready after all stages (inquiry + 3 radio restarts + MEDIA cycle + parent-node cycle). Music script will retry at 9AM."
exit 1
