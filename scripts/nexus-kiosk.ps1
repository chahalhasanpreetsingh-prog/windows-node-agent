param([ValidateSet("dashboard","frame")] [string]$Mode = "")

# Kiosk on the HDMI panel (\\.\DISPLAY1). Two modes:
#   dashboard - Nexus UI on the server:3330
#   frame     - Immich photo frame (a family member's library) on the server:3340
# Renders on the AMD iGPU by design; the RTX 3050 stays reserved for game render + NVENC.
$brave    = "$env:USERPROFILE\AppData\Local\BraveSoftware\Brave-Browser\Application\brave.exe"
$profile  = "$env:USERPROFILE\nexus-kiosk-profile"
$log      = "$env:USERPROFILE\nexus-kiosk.log"
$modeFile = "$env:USERPROFILE\nexus-kiosk-mode.txt"

$URLS = @{
  dashboard = "http://<server-ip>:3330"
  frame     = "http://<server-ip>:3340/?k=-6b_xPFCnkBfnShbHqoUXZpnXeMkfF8M&sec=14"
}
$PROBE = @{
  dashboard = "http://<server-ip>:3330"
  frame     = "http://<server-ip>:3340/healthz"
}

function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content -Path $log }

# No -Mode given (e.g. the at-logon trigger): resume whatever mode was last selected.
if (-not $Mode) {
  if (Test-Path $modeFile) { $Mode = (Get-Content $modeFile -Raw).Trim() }
  if ($URLS.Keys -notcontains $Mode) { $Mode = "dashboard" }
}
Set-Content -Path $modeFile -Value $Mode -Encoding ASCII

Log "--- kiosk start requested (mode=$Mode) ---"
if (-not (Test-Path $brave)) { Log "FATAL: brave not found at $brave"; exit 1 }

Get-CimInstance Win32_Process -Filter "Name='brave.exe'" |
  Where-Object { $_.CommandLine -like "*nexus-kiosk-profile*" } |
  ForEach-Object { Log ("killing stale kiosk pid " + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3

# Suppress Brave's P3A consent bar - re-applied every launch so a profile reset can't restore it
$ls = Join-Path $profile "Local State"
if (Test-Path $ls) {
  try {
    $j = Get-Content $ls -Raw | ConvertFrom-Json
    if (-not $j.brave) { $j | Add-Member -NotePropertyName brave -NotePropertyValue ([pscustomobject]@{}) -Force }
    $j.brave | Add-Member -NotePropertyName p3a -NotePropertyValue ([pscustomobject]@{ enabled = $false; notice_acknowledged = $true; enabled_by_policy = $false }) -Force
    $j.brave | Add-Member -NotePropertyName stats -NotePropertyValue ([pscustomobject]@{ reporting_enabled = $false }) -Force
    $j | ConvertTo-Json -Depth 100 -Compress | Set-Content -Path $ls -Encoding UTF8
    Log "patched Local State: p3a disabled"
  } catch { Log ("WARN: could not patch Local State: " + $_) }
}

$ok = $false
for ($i = 0; $i -lt 60; $i++) {
  try { if ((Invoke-WebRequest -Uri $PROBE[$Mode] -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) { $ok = $true; break } } catch { }
  Start-Sleep -Seconds 5
}
Log ("backend reachable: " + $ok)

# Wait for the HDMI panel, else the window would land on the VDD and be streamed to Moonlight
Add-Type -AssemblyName System.Windows.Forms
$panel = @()
for ($i = 0; $i -lt 30; $i++) {
  $panel = @([System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary })
  if ($panel.Count -gt 0) { break }
  Start-Sleep -Seconds 2
}
if ($panel.Count -eq 0) { Log "FATAL: no secondary display, refusing to launch on the VDD"; exit 1 }
$b = $panel[0].Bounds
Log ("panel $($panel[0].DeviceName) at $($b.X),$($b.Y) $($b.Width)x$($b.Height)")

$bargs = @(
  "--user-data-dir=$profile"
  "--kiosk"
  "--window-position=$($b.X),$($b.Y)"
  "--window-size=$($b.Width),$($b.Height)"
  "--start-fullscreen"
  "--no-first-run"
  "--no-default-browser-check"
  "--disable-session-crashed-bubble"
  "--hide-crash-restore-bubble"
  "--noerrdialogs"
  "--disable-infobars"
  "--disable-pinch"
  "--overscroll-history-navigation=0"
  "--disable-features=Translate,TranslateUI,BraveWelcomeUI,BraveRewards,BraveVPN,InfiniteSessionRestore"
  "--password-store=basic"
  "--force-device-scale-factor=1"
  $URLS[$Mode]
)
Start-Process -FilePath $brave -ArgumentList $bargs
Log "launched ($Mode)"
