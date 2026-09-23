# windows-node-agent

A small HTTP agent that makes a headless Windows machine controllable from a Linux dashboard:
system metrics, Docker inside WSL2, game streaming, Bluetooth audio and music playback, all
behind a shared-token header.

About 1,400 lines of PowerShell, running as a scheduled task on my laptop. The dashboard that
consumes it is [nexus-ui](https://github.com/chahalhasanpreetsingh-prog/nexus-ui).

## Why an agent instead of SSH

SSH into Windows lands in session 0. GUI apps either fail or kill themselves there, quoting
breaks across the cmd.exe and PowerShell and WSL boundary, and long jobs die with the session.
An agent running as a scheduled task sidesteps all three, and gives the dashboard a stable JSON
API instead of screen-scraped command output.

## What it exposes

* Metrics: CPU, memory, uptime, disks, including disks that only exist inside WSL2
* Docker: list, inspect, logs, start, stop and restart of containers in the WSL2 VM
* Game streaming: status, start and stop for the Sunshine host
* Media: play, shuffle, stop and status via mpv's IPC socket, plus a check that the Bluetooth
  speaker really is the default output device before anything plays
* Bluetooth: connection status and a reconnect routine

Every request needs the `X-Nexus-Agent-Token` header. The token is read from a file on disk, not
baked into the script, and the listener binds a single prefix.

## The supporting scripts

`bt-preconnect.ps1` and `bt-keepalive.ps1` deal with a Bluetooth stack that reports a healthy
device while no audio reaches it. The preconnect cycles the radio several times, and the
keepalive plays a silent wav on an interval so the speaker never sleeps between songs.

`wsl_start_and_mount.ps1` brings up the WSL2 VM and attaches the USB disks it serves, in a fixed
order, logging each step. `wsl_keepalive_wrapper.ps1` keeps the VM from being reclaimed.

`nexus-kiosk.ps1` drives a wall-mounted panel between a dashboard mode and a photo-frame mode.
`navidrome-shuffle-play.ps1` and `nexus-shuffle-loop.ps1` are the music paths behind the agent's
media endpoints. `boot_vdd_fix.ps1` re-applies the virtual display driver after a reboot, which a
headless machine with the lid shut needs before anything can render.

## Running it

```powershell
$env:AGENT_TOKEN_FILE = "$env:USERPROFILE\.nexus-agent-token"
$env:AGENT_MACHINE_ID = "laptop"
$env:ND_URL  = "http://server:4533"
$env:ND_AUTH = "u=user&t=<token>&s=<salt>&v=1.16.1&c=agent"   # Subsonic salted-token auth
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\nexus-laptop-agent.ps1
```

Register it as a scheduled task set to run at logon so it survives reboots.

MIT licensed.
