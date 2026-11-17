<#
Setup-Lumen-Windows.ps1
========================
Installs the Lumen text server on this Windows PC so the iPhone app can reach it.

Speech stays on the iPhone. This script does not install a speech model.

What it does
  1. Installs Python 3.12 with winget if it is missing (your user only).
  2. Copies the server to %LOCALAPPDATA%\Lumen.
  3. Adds a scheduled task "Lumen Server" that starts it hidden when you sign in.
  4. Publishes it on your Tailscale network over HTTPS when Tailscale is installed.

HOW TO RUN (normal PowerShell, not admin)
  powershell -ExecutionPolicy Bypass -File .\Setup-Lumen-Windows.ps1

The folder next to this script must contain an "app" folder with server.py.
Put the provider key in server config or in LUMEN_PROVIDER_KEY. With no key, text
goes to Ollama on this PC if it is running.

AFTER SETUP
  Lumen on Windows is at https://<this PC's Tailscale name>.<your-tailnet>.ts.net
  Use that address and the token from config.json in the iPhone app.
  Log: %LOCALAPPDATA%\Lumen\logs\lumen.log

UNINSTALL
  powershell -ExecutionPolicy Bypass -File .\Setup-Lumen-Windows.ps1 -Uninstall
#>
[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$TaskName = 'Lumen Server'
$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Src      = Join-Path $Here 'app'
$Dest     = Join-Path $env:LOCALAPPDATA 'Lumen'
$TS       = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'

function Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*\Lumen\*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (Test-Path $TS) { & $TS serve --https=443 off 2>$null | Out-Null }
    Write-Host "Lumen task removed and Tailscale Serve turned off. Files are still in $Dest (delete that folder to remove them)."
    return
}

if (-not (Test-Path (Join-Path $Src 'server.py'))) { throw "Can't find the 'app' folder next to this script." }

Step "Checking Python 3.12"
$Py = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
if (-not (Test-Path $Py)) {
    $c = Get-Command py -ErrorAction SilentlyContinue
    if ($c) {
        $ErrorActionPreference = 'Continue'
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

Step "Copying Lumen to $Dest"
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
robocopy $Src $Dest /E /NFL /NDL /NJH /NJS /NP /XF (Join-Path $Src 'config.json') | Out-Null
$cfgPath = Join-Path $Dest 'config.json'

Step "Adding the '$TaskName' task"
$action    = New-ScheduledTaskAction -Execute $PyW -Argument "-I `"$Dest\server.py`"" -WorkingDirectory $Dest
$trigger   = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"))
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
               -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force `
    -Description 'Lumen text server for the iPhone app (127.0.0.1:4100).' | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "Waiting for Lumen to start..."
$ok = $false
$token = ''
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    if ((Test-Path $cfgPath) -and -not $token) {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $token = $cfg.token
    }
    if ($token) {
        try {
            $r = Invoke-RestMethod -Uri 'http://127.0.0.1:4100/api/status' -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 5
            if ($r.ok) { $ok = $true; break }
        } catch { }
    }
}
if (-not $ok) { throw "Lumen didn't start. Check $Dest\logs\lumen.log" }

Step "Publishing on Tailscale"
if (Test-Path $TS) {
    & $TS serve --bg --https=443 http://127.0.0.1:4100 | Out-Host
    $dns = ((& $TS status --self --json | ConvertFrom-Json).Self.DNSName).TrimEnd('.')
    Write-Host ""
    Write-Host "Lumen on this PC: https://$dns" -ForegroundColor Green
    Write-Host "Use that address and the token in $cfgPath in the iPhone app."
} else {
    Write-Host "Tailscale isn't installed here, so Lumen only works on this PC (http://127.0.0.1:4100)."
}
Write-Host ""
Write-Host "Done. Lumen starts by itself whenever you sign in to Windows." -ForegroundColor Green
