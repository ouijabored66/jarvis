<#
Setup-Jarvis-Windows.ps1
========================
Installs Jarvis (the same assistant that runs on the Nobara/Linux side) on this
Windows PC, so your iPhone app can still reach Jarvis when the
desktop is booted into Windows.

It uses the files next to this script (the "app" folder): the Jarvis server,
the hearing worker (Whisper, model included) and the voice worker (Kokoro,
model included). It does NOT need the internet for the speech models.

What it does
  1. Installs Python 3.12 and ffmpeg with winget if they're missing (your user only).
  2. Checks Claude Code is installed and signed in (Jarvis's "brain").
  3. Copies Jarvis to %LOCALAPPDATA%\Jarvis and installs its Python libraries.
  4. Adds a scheduled task "Jarvis Server" that starts Jarvis hidden when you sign in.
  5. Publishes Jarvis on your Tailscale network over HTTPS.

HOW TO RUN (normal PowerShell, not admin)
  1. Make sure Claude Code is installed and you've signed in once:
         irm https://claude.ai/install.ps1 | iex      (then open a new window, run: claude, sign in, /exit)
  2. Run this script from this folder:
         powershell -ExecutionPolicy Bypass -File .\Setup-Jarvis-Windows.ps1

AFTER SETUP
  Jarvis on Windows lives at https://<this PC's Tailscale name>.<your-tailnet>.ts.net
  (the script prints it). It uses the same tokens as the Linux Jarvis, so the
  iPhone app keeps working - only the server address differs.
  Log: %LOCALAPPDATA%\Jarvis\logs\jarvis.log

UNINSTALL
  powershell -ExecutionPolicy Bypass -File .\Setup-Jarvis-Windows.ps1 -Uninstall
#>
[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$TaskName = 'Jarvis Server'
$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Src      = Join-Path $Here 'app'
$Dest     = Join-Path $env:LOCALAPPDATA 'Jarvis'
$TS       = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'

function Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*\Jarvis\*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (Test-Path $TS) { & $TS serve --https=443 off 2>$null | Out-Null }
    Write-Host "Jarvis task removed and Tailscale Serve turned off. Files are still in $Dest (delete that folder to remove them)."
    return
}

if (-not (Test-Path (Join-Path $Src 'server.py'))) { throw "Can't find the 'app' folder next to this script." }

# ---------------------------------------------------------------- 1. Python 3.12 + ffmpeg
Step "Checking Python 3.12"
$Py = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
if (-not (Test-Path $Py)) {
    $c = Get-Command py -ErrorAction SilentlyContinue
    if ($c) {
        $ErrorActionPreference = 'Continue'   # PS 5.1 turns a native program's stderr into a fatal error under 'Stop'
        $p = & py -3.12 -c "import sys;print(sys.executable)" 2>$null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -eq 0 -and $p) { $Py = "$p".Trim() }
    }
}
if (-not (Test-Path $Py)) {
    Write-Host "Installing Python 3.12 for your user (winget)..."
    winget install --id Python.Python.3.12 -e --scope user --silent --accept-package-agreements --accept-source-agreements | Out-Host
    $Py = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
    if (-not (Test-Path $Py)) { throw "Python 3.12 didn't install. Install it from python.org (for your user) and run this again." }
}
$PyW = Join-Path (Split-Path $Py) 'pythonw.exe'
Write-Host "Python: $Py"

Step "Checking ffmpeg"
function Find-Ffmpeg {
    $c = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($c) { return (Split-Path $c.Source) }
    $hit = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.DirectoryName }
    return $null
}
$FfDir = Find-Ffmpeg
if (-not $FfDir) {
    Write-Host "Installing ffmpeg (winget)..."
    winget install --id Gyan.FFmpeg -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
    $FfDir = Find-Ffmpeg
    if (-not $FfDir) { throw "ffmpeg didn't install. Run: winget install Gyan.FFmpeg   then run this again." }
}
Write-Host "ffmpeg: $FfDir"

# ---------------------------------------------------------------- 2. Claude Code
Step "Checking Claude Code"
$Claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
if (-not (Test-Path $Claude)) { $c = Get-Command claude -ErrorAction SilentlyContinue; if ($c) { $Claude = $c.Source } }
if (-not (Test-Path $Claude)) {
    throw "Claude Code isn't installed. Run:  irm https://claude.ai/install.ps1 | iex   then open a new PowerShell, run 'claude', sign in, /exit, and run this script again."
}
$ErrorActionPreference = 'Continue'
$test = & $Claude -p "Reply with the single word: ready" --tools "" 2>&1 | Out-String
$ErrorActionPreference = 'Stop'
if ($test -notmatch 'ready') {
    Write-Host $test
    throw "Claude Code didn't answer. Open PowerShell, run 'claude' and sign in, then run this script again."
}
Write-Host "Claude Code: $Claude (signed in)"

# ---------------------------------------------------------------- 3. Copy Jarvis + libraries
Step "Copying Jarvis to $Dest"
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
# exclude only the top-level config.json (a bare "/XF config.json" also drops the Whisper model's config.json)
robocopy $Src $Dest /E /NFL /NDL /NJH /NJS /NP /XF (Join-Path $Src 'config.json') | Out-Null
$cfgPath = Join-Path $Dest 'config.json'
$srcCfg = Join-Path $Src 'config.json'
if (Test-Path $srcCfg) {
    $cfg = Get-Content $srcCfg -Raw | ConvertFrom-Json
    if (Test-Path $cfgPath) {           # keep a voice choice made on this PC
        $old = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($old.voice) { $cfg.voice = $old.voice }
    }
} elseif (Test-Path $cfgPath) {         # Windows-only config already in place
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
} else { throw "No config.json found in $Src or $Dest." }
$cfg | Add-Member -NotePropertyName ffmpeg_dir -NotePropertyValue $FfDir -Force
# UTF-8 without BOM: Python's json.load can't read a BOM
[IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
# config.json holds the access tokens: only you can read it
icacls $cfgPath /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null

foreach ($w in @(@{n='hear'; pk='faster-whisper'}, @{n='speak'; pk='kokoro-onnx soundfile'})) {
    $venv = Join-Path $Dest "$($w.n)\.venv"
    if (-not (Test-Path (Join-Path $venv 'Scripts\python.exe'))) {
        Write-Host "Creating $($w.n) environment..."
        & $Py -m venv $venv
    }
    Write-Host "Installing $($w.pk)..."
    & (Join-Path $venv 'Scripts\python.exe') -m pip install -q --disable-pip-version-check $($w.pk.Split(' '))
    if ($LASTEXITCODE -ne 0) { throw "Installing $($w.pk) failed." }
}

# ---------------------------------------------------------------- 4. Scheduled task (hidden, at sign-in)
Step "Adding the '$TaskName' task"
$action    = New-ScheduledTaskAction -Execute $PyW -Argument "-I `"$Dest\server.py`"" -WorkingDirectory $Dest
# Starts at boot without anyone signing in (S4U = run as you, no stored password); logon trigger is a backup.
$trigger   = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"))
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
               -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force `
    -Description 'Jarvis assistant for the iPhone app (127.0.0.1:4100).' | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "Waiting for Jarvis to start (first start loads the speech models)..."
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 3
    try {
        $r = Invoke-RestMethod -Uri 'http://127.0.0.1:4100/api/status' -Headers @{ Authorization = "Bearer $($cfg.token)" } -TimeoutSec 5
        if ($r.ok) { $ok = $true; break }
    } catch { }
}
if (-not $ok) { throw "Jarvis didn't start. Check $Dest\logs\jarvis.log and $Dest\logs\*.err" }
$ans = Invoke-RestMethod -Uri 'http://127.0.0.1:4100/api/text' -Method Post -ContentType 'application/json' `
        -Headers @{ Authorization = "Bearer $($cfg.token)" } -Body '{"text":"Reply with just: Jarvis online on Windows."}' -TimeoutSec 120
Write-Host "Jarvis says: $($ans.say)" -ForegroundColor Green

# ---------------------------------------------------------------- 5. Tailscale
Step "Publishing on Tailscale"
if (Test-Path $TS) {
    & $TS serve --bg --https=443 http://127.0.0.1:4100 | Out-Host
    $dns = ((& $TS status --self --json | ConvertFrom-Json).Self.DNSName).TrimEnd('.')
    Write-Host ""
    Write-Host "Jarvis on this PC: https://$dns" -ForegroundColor Green
    Write-Host "Use that address in the iPhone app (Settings) when the desktop is in Windows."
} else {
    Write-Host "Tailscale isn't installed here, so Jarvis only works on this PC (http://127.0.0.1:4100)."
}
Write-Host ""
Write-Host "Done. Jarvis starts by itself whenever you sign in to Windows." -ForegroundColor Green
