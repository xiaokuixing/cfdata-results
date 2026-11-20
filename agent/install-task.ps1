#Requires -Version 5.1
<#
    注册 / 删除每 N 分钟运行一次的计划任务。

    用 wscript.exe 调 run-agent.vbs 来启动 PowerShell（窗口样式 0），
    这样任务触发时不会闪黑色控制台窗口。

    用法：
        powershell -ExecutionPolicy Bypass -File .\install-task.ps1
        powershell -ExecutionPolicy Bypass -File .\install-task.ps1 -Minutes 5
        powershell -ExecutionPolicy Bypass -File .\install-task.ps1 -Remove
#>
[CmdletBinding()]
param(
    [int]$Minutes = 1,
    [string]$TaskName = 'cfdata-tg-agent',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$agent = Join-Path $PSScriptRoot 'agent.ps1'
$vbs = Join-Path $PSScriptRoot 'run-agent.vbs'

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

$vbsLines = @(
    'Set sh = CreateObject("WScript.Shell")',
    ('sh.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{0}""", 0, False' -f $agent)
)
[IO.File]::WriteAllText($vbs, (($vbsLines -join "`r`n") + "`r`n"), (New-Object Text.UnicodeEncoding($false, $true)))
Write-Host "已生成无窗口启动器：$vbs"

try {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B //Nologo "{0}"' -f $vbs)
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
        -RepetitionInterval (New-TimeSpan -Minutes $Minutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 90) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Description 'Telegram shared IP -> cfdata speed test -> GitHub' -Force | Out-Null

    Write-Host "已注册计划任务：$TaskName（每 $Minutes 分钟，无窗口）"
} catch {
    Write-Host "计划任务 cmdlet 不可用，改用 schtasks：$($_.Exception.Message)"
    $taskCommand = 'wscript.exe //B //Nologo \"{0}\"' -f $vbs
    & schtasks.exe /Create /TN $TaskName /SC MINUTE /MO $Minutes /TR $taskCommand /F
    if ($LASTEXITCODE -ne 0) { throw 'schtasks 创建失败' }
    Write-Host "已注册计划任务：$TaskName（每 $Minutes 分钟，无窗口）"
}

Write-Host "手动测试：powershell -ExecutionPolicy Bypass -File `"$agent`" -Force"
