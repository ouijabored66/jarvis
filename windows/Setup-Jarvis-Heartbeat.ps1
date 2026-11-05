<#
Setup-Jarvis-Heartbeat.ps1 - tells the Apple Watch "Ask Jarvis" Shortcut that Windows is running.
Posts this PC's Jarvis address to a private ntfy.sh status topic at boot and every 30 minutes.
(The Linux side posts its own address to the same topic.)
Reads "status_topic" and "public_url" from %LOCALAPPDATA%\Jarvis\config.json. Run once in normal PowerShell:
    powershell -ExecutionPolicy Bypass -File .\Setup-Jarvis-Heartbeat.ps1
#>
$cfg   = Get-Content (Join-Path $env:LOCALAPPDATA 'Jarvis\config.json') -Raw | ConvertFrom-Json
$Topic = $cfg.status_topic
$Url   = $cfg.public_url.TrimEnd('/') + '/api/text'
if (-not $Topic -or -not $cfg.public_url) { throw 'Set status_topic and public_url in config.json first.' }
$Cmd = "Invoke-RestMethod -Method Post -Uri 'https://ntfy.sh/$Topic' -Headers @{Cache='yes'} -Body '$Url' -TimeoutSec 20 | Out-Null"
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `"$Cmd`""
$boot    = New-ScheduledTaskTrigger -AtStartup
$boot.Delay = 'PT1M'
$repeat  = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 30)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'Jarvis Heartbeat' -Action $action -Trigger @($boot,$repeat) -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'Jarvis Heartbeat'
Start-Sleep 5
Write-Host ("Status now: " + (Invoke-RestMethod "https://ntfy.sh/$Topic/raw?poll=1&since=latest"))
