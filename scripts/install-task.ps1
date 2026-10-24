# Registers (or with -Remove, deletes) the Windows scheduled task that runs autobuilder
# a few minutes after you log in. run-daily.ps1 itself makes sure it only works once per day.
param([switch]$Remove, [int]$DelayMinutes = 5)

$taskName = 'Autobuilder Daily'
if ($Remove) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed '$taskName'."
    exit 0
}

$script = Join-Path $PSScriptRoot 'run-daily.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"" `
    -WorkingDirectory (Split-Path -Parent $PSScriptRoot)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$trigger.Delay = "PT${DelayMinutes}M"
# Also unlocking the laptop counts as "opening it" when you never fully log out.
$unlock = Get-CimClass -Namespace ROOT\Microsoft\Windows\TaskScheduler -ClassName MSFT_TaskSessionStateChangeTrigger
$unlockTrigger = New-CimInstance -CimClass $unlock -ClientOnly -Property @{ StateChange = 8; UserId = "$env:USERDOMAIN\$env:USERNAME"; Delay = "PT${DelayMinutes}M" }
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger, $unlockTrigger) -Settings $settings `
    -Description 'Builds the next stage of approved autobuilder projects (once per day).' -Force | Out-Null
Write-Host "Registered '$taskName': runs $DelayMinutes min after log-on or unlock, at most once per day."
