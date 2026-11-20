#Requires -Version 5.1
<#
    本地测速 agent
    检测 shared-ips.txt 是否有更新，有更新就调用本地 cfdata 做非标优选，
    筛选条件与上传全部交给 cfdata 自己完成（-nsbsourceurl + -github）。

    由 Windows 计划任务每隔 N 分钟调用一次，单次执行完即退出。
#>
[CmdletBinding()]
param(
    [string]$Config = '',
    [switch]$Force,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $Config) { $Config = Join-Path $PSScriptRoot 'agent.config.json' }

$script:scriptDir = $PSScriptRoot
$script:logDir = Join-Path $scriptDir 'logs'
$script:logFile = Join-Path $logDir ('agent-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Get-RawValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-Str {
    param($Object, [string]$Name, [string]$Default)
    $value = Get-RawValue $Object $Name
    if ($null -eq $value -or ([string]$value).Trim() -eq '') { return $Default }
    return [string]$value
}

function Get-Num {
    param($Object, [string]$Name, $Default)
    $value = Get-RawValue $Object $Name
    if ($null -eq $value -or ([string]$value).Trim() -eq '') { return $Default }
    return $value
}

function Format-Number {
    param($Value)
    return ([double]$Value).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
}

function Add-Arg {
    param([System.Collections.Generic.List[string]]$List, [string]$Flag, $Value)
    if ($null -eq $Value -or ([string]$Value).Trim() -eq '') { return }
    $List.Add($Flag)
    $List.Add([string]$Value)
}

function Add-BoolArg {
    param([System.Collections.Generic.List[string]]$List, [string]$Flag, $Value)
    if ($null -eq $Value) { return }
    $List.Add(('{0}={1}' -f $Flag, ([bool]$Value).ToString().ToLowerInvariant()))
}

function Quote-Args {
    param([System.Collections.Generic.List[string]]$List)
    return $List | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }
}

if (-not (Test-Path -LiteralPath $Config)) {
    throw "找不到配置文件：$Config（先复制 agent.config.example.json 为 agent.config.json 再修改）"
}

$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json

$repo = Get-Str $cfg 'repo' 'xiaokuixing/cfdata-results'
$branch = Get-Str $cfg 'branch' 'main'
$inboxPath = Get-Str $cfg 'inboxPath' 'shared-ips.txt'
$uploadPath = Get-Str $cfg 'uploadPath' 'results.txt'
$exe = [Environment]::ExpandEnvironmentVariables((Get-Str $cfg 'cfdataExe' ''))
$tokenFile = [Environment]::ExpandEnvironmentVariables((Get-Str $cfg 'tokenFile' '%USERPROFILE%\.cfdata-results\gh-token.txt'))
$timeoutMinutes = [int](Get-Num $cfg 'timeoutMinutes' 30)
$proxy = Get-Str $cfg 'proxy' ''
$sourceUrl = Get-Str $cfg 'sourceUrl' ''
if (-not $sourceUrl) {
    $sourceUrl = "https://raw.githubusercontent.com/$repo/$branch/$inboxPath"
}

$params = Get-RawValue $cfg 'params'

$argList = New-Object 'System.Collections.Generic.List[string]'
$argList.Add('-cli')
Add-Arg $argList '-mode' 'nsb'
Add-Arg $argList '-nsbsourceurl' $sourceUrl
Add-Arg $argList '-nsbthreads' (Get-Num $params 'threads' 100)
Add-Arg $argList '-nsbspeedtest' (Get-Num $params 'speedThreads' 1)
Add-Arg $argList '-nsbspeedmin' (Format-Number (Get-Num $params 'speedMin' 8.0))
Add-Arg $argList '-nsbspeedlimit' (Get-Num $params 'speedLimit' 10)
Add-Arg $argList '-nsbresultlimit' (Get-Num $params 'resultLimit' 500)
Add-Arg $argList '-nsbdelay' (Get-Num $params 'delay' 0)
Add-BoolArg $argList '-nsbtls' (Get-RawValue $params 'tls')
Add-BoolArg $argList '-relink' (Get-RawValue $params 'relink')

Add-Arg $argList '-out' 'cfdata-run'
Add-Arg $argList '-outformat' 'txt'
Add-Arg $argList '-outfields' 'dc,speed,region'
$argList.Add('-outseparator=-')
Add-Arg $argList '-outstartrow' 1
Add-Arg $argList '-outendrow' 0
Add-Arg $argList '-outqualified' 'qualified'
Add-Arg $argList '-outiptype' 'all'
$argList.Add('-nocolor')
$argList.Add('-progress=false')
$argList.Add('-skipgeo')
if ($proxy) { Add-Arg $argList '-proxy' $proxy }

$argList.Add('-github')
Add-Arg $argList '-ghrepo' $repo
Add-Arg $argList '-ghbranch' $branch
Add-Arg $argList '-ghpath' $uploadPath
Add-Arg $argList '-ghtokenfile' $tokenFile
Add-Arg $argList '-ghmessage' 'update results from shared inbox'

if ($SelfTest) {
    Write-Host "配置:      $Config"
    Write-Host "cfdata:    $exe"
    Write-Host "来源:      $sourceUrl"
    Write-Host "上传到:    $repo / $branch / $uploadPath"
    Write-Host "token:     $tokenFile"
    Write-Host ""
    Write-Host "命令:"
    Write-Host ("  `"$exe`" " + ((Quote-Args $argList) -join ' '))
    exit 0
}

if (-not (Test-Path -LiteralPath $exe)) {
    throw "cfdata 可执行文件不存在：$exe（修改 agent.config.json 里的 cfdataExe）"
}
if (-not (Test-Path -LiteralPath $tokenFile)) {
    throw "GitHub token 文件不存在：$tokenFile"
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\cfdata-tg-agent')
if (-not $mutex.WaitOne(0)) {
    Write-Log '上一轮还在运行，跳过本轮'
    exit 0
}

$tempDir = Join-Path $env:TEMP ('cfdata-agent-' + [guid]::NewGuid().ToString('N'))
$stateFile = Join-Path $scriptDir 'state.json'
$exitCode = 0

try {
    $headers = @{}
    $state = $null
    if (Test-Path -LiteralPath $stateFile) {
        try { $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
    }
    $etag = Get-RawValue $state 'etag'
    if (-not $Force -and $etag) { $headers['If-None-Match'] = [string]$etag }

    Write-Log "检查来源：$sourceUrl"
    try {
        $response = Invoke-WebRequest -Uri $sourceUrl -Headers $headers -UseBasicParsing -TimeoutSec 30
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 304) {
            Write-Log '来源没有更新，跳过'
            exit 0
        }
        throw "下载来源失败（$status）：$($_.Exception.Message)"
    }

    $newEtag = $null
    if ($response.Headers -and $response.Headers['ETag']) { $newEtag = [string]$response.Headers['ETag'] }

    $lines = @($response.Content -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })
    if ($lines.Count -eq 0) {
        Write-Log '来源文件为空，跳过'
        exit 0
    }
    Write-Log ("来源共 {0} 条，开始调用 cfdata" -f $lines.Count)

    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $quoted = Quote-Args $argList
    $arguments = ($quoted -join ' ')

    $attempt = 0
    $output = ''
    $cfdataExit = 0
    while ($attempt -lt 2) {
        $attempt += 1

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $arguments
        $psi.WorkingDirectory = $tempDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        if (-not $proc.Start()) { throw '无法启动 cfdata' }

        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($timeoutMinutes * 60 * 1000)) {
            try { $proc.Kill() } catch { }
            throw "cfdata 运行超过 $timeoutMinutes 分钟，已终止"
        }

        $output = $outTask.Result
        $errText = $errTask.Result
        if ($errText) { $output = $output + "`n" + $errText }
        if ($null -eq $output) { $output = '' }
        $cfdataExit = $proc.ExitCode

        if ($output -match '\[config\]' -and $attempt -eq 1) {
            Write-Log '首次运行生成了 cfdata 配置文件，重试一次'
            continue
        }
        break
    }

    $tail = @($output -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 12)
    foreach ($line in $tail) { Write-Log ("cfdata | " + $line) }

    if ($cfdataExit -ne 0) {
        Write-Log "cfdata 退出码 $cfdataExit，本轮不记录更新状态"
        $exitCode = 1
    } else {
        if ($newEtag) {
            $stateObject = [ordered]@{ etag = $newEtag; lastRun = (Get-Date).ToString('s'); source = $sourceUrl }
            [IO.File]::WriteAllText($stateFile, ($stateObject | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        }
        Write-Log '本轮完成'
    }
} catch {
    Write-Log ("出错：" + $_.Exception.Message)
    $exitCode = 1
} finally {
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

exit $exitCode