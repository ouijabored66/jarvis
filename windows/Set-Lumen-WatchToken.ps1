<#
Set-Lumen-WatchToken.ps1 - makes the Windows Lumen accept the Linux Watch token,
so one Apple Watch Shortcut works on both systems. The token is typed in hidden and never shown.
Run in normal PowerShell:
    powershell -ExecutionPolicy Bypass -File .\Set-Lumen-WatchToken.ps1
#>
$path = Join-Path $env:LOCALAPPDATA 'Lumen\config.json'
$sec  = Read-Host 'Paste the Linux Watch token (hidden)' -AsSecureString
$tok  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
$tok  = $tok.Trim()
if ($tok.Length -lt 16) { Write-Host 'That looks too short. Nothing changed.'; exit 1 }

Copy-Item $path "$path.bak" -Force
$cfg = Get-Content $path -Raw | ConvertFrom-Json
$cfg.tokens.watch = $tok
[IO.File]::WriteAllText($path, ($cfg | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))

Stop-ScheduledTask -TaskName 'Lumen Server'
Start-Sleep 3
Start-ScheduledTask -TaskName 'Lumen Server'
Start-Sleep 10
try {
    $r = Invoke-RestMethod 'http://127.0.0.1:4100/api/status' -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec 5
    Write-Host ("Watch token accepted by Windows Lumen: ok = " + $r.ok)
} catch { Write-Host ('Check failed: ' + $_.Exception.Message) }
