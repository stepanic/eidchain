# Keep the WSL distro that runs an eidchain node (deploy/linux/install.sh) up from
# Windows boot, with nobody logged on, and keep the machine awake on mains power.
# Run once, in an elevated PowerShell:
#
#   powershell -ExecutionPolicy Bypass -File \\wsl.localhost\Ubuntu\home\user\git\stepanic\eidchain\deploy\wsl\keep-alive.ps1
#   ... -Remove        takes the task out again (power and .wslconfig stay)
#
# Why: WSL starts a distro only when something runs wsl.exe, and stops it soon
# after the last wsl.exe exits, systemd services or not. So a task started at
# boot holds one wsl.exe open (sleep infinity) for as long as Windows runs. S4U
# runs it as this user without a stored password and without a logon.
# vmIdleTimeout=-1 keeps the VM up in the minute the task needs to come back if
# that process ever dies. A laptop that sleeps takes the node with it, so sleep,
# hibernation and the lid are turned off on AC; on battery it may still sleep.
param(
  [string]$Distro = "Ubuntu",
  [string]$User = "$env:USERDOMAIN\$env:USERNAME",
  [switch]$Remove
)
$ErrorActionPreference = "Stop"
$TaskName = "eidchain WSL keep-alive"

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw "run in an elevated PowerShell (Run as administrator)" }

if ($Remove) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "task '$TaskName' removed"
  return
}

Write-Host "== scheduled task"
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wsl.exe" -Argument "-d $Distro --exec /bin/sleep infinity"
# At boot, and again every 5 minutes: IgnoreNew makes a repeat a no-op while the
# first one runs, and restarts it if it has died.
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
  -Settings $settings -Description "Keeps WSL ($Distro) running for the eidchain node" -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "   '$TaskName' registered for $User and started"

Write-Host "== .wslconfig"
$cfg = Join-Path $env:USERPROFILE ".wslconfig"
$text = if (Test-Path $cfg) { Get-Content $cfg -Raw } else { "" }
if ($text -match '(?m)^\s*vmIdleTimeout\s*=') {
  Write-Host "   $cfg already sets vmIdleTimeout, left as is: it should be -1"
} elseif ($text -match '(?m)^\s*\[wsl2\]\s*$') {
  $text = $text -replace '(?m)^(\s*\[wsl2\]\s*)$', "`$1`r`nvmIdleTimeout=-1"
  Set-Content -Path $cfg -Value $text -NoNewline
  Write-Host "   vmIdleTimeout=-1 added to [wsl2]"
} else {
  Add-Content -Path $cfg -Value "`r`n[wsl2]`r`nvmIdleTimeout=-1"
  Write-Host "   [wsl2] vmIdleTimeout=-1 written"
}

Write-Host "== power (AC only)"
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setactive SCHEME_CURRENT
Write-Host "   on AC: no sleep, no hibernation, closing the lid does nothing"
Write-Host "done. Check after a reboot, before logging on, from another machine:"
Write-Host "   curl https://<DOMAIN>/chain/api/v1/info"
