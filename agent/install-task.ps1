#Requires -Version 5.1
<#
    注册 / 删除每 N 分钟运行一次的计划任务。
    用法：
        powershell -ExecutionPolicy Bypass -File .\install-task.ps1
        powershell -ExecutionPolicy Bypass -File .\install-task.ps1 -Minutes 15
        powershell -ExecutionPolicy Bypass -File .\install-task.ps1 -Remove
#>
[CmdletBinding()]
param(
    [int]$Minutes = 10,
    [string]$TaskName = 'cfdata-tg-agent',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$agent = Join-Path $PSScriptRoot 'agent.ps1'

if (-not (Test-Path -LiteralPath $agent)) {
    throw "找不到 agent.ps1：$agent"
}

if ($Remove) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "已删除计划任务：$TaskName"
    } catch {
        & schtasks.exe /Delete /TN $TaskName /F | Out-Null
        Write-Host "已删除计划任务：$TaskName"
    }
    exit 0
}

$command = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $agent

try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $agent)
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
        -RepetitionInterval (New-TimeSpan -Minutes $Minutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 90) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Description 'Telegram shared IP -> cfdata speed test -> GitHub' -Force | Out-Null

    Write-Host "已注册计划任务：$TaskName（每 $Minutes 分钟）"
} catch {
    Write-Host "计划任务 cmdlet 不可用，改用 schtasks：$($_.Exception.Message)"
    $taskCommand = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"{0}\"' -f $agent
    & schtasks.exe /Create /TN $TaskName /SC MINUTE /MO $Minutes /TR $taskCommand /F
    if ($LASTEXITCODE -ne 0) { throw 'schtasks 创建失败' }
    Write-Host "已注册计划任务：$TaskName（每 $Minutes 分钟）"
}

Write-Host "手动测试：powershell -ExecutionPolicy Bypass -File `"$agent`" -Force"