#Requires -Version 5.1
<#
    本地测速 agent
    检测 shared-ips.txt 是否有变化，有变化就调用本地 cfdata 做非标优选，
    筛选条件与上传全部交给 cfdata 自己完成。

    来源默认走 GitHub API（api.github.com，国内通常比 raw 稳定），
    下载后以 -nsbfile 交给 cfdata；sourceMode=url 时退回 -nsbsourceurl。
#>
[CmdletBinding()]
param(
    [string]$Config = '',
    [switch]$Force,
    [switch]$SelfTest,
    [string]$SourceFile = ''
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
    param($List)
    return $List | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }
}

function Get-ContentHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Get-LocalProxyCandidates {
    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $names = @('clash-core-service', 'FlClashCore', 'FlClash', 'mihomo', 'clash-verge', 'verge-mihomo', 'clash', 'sing-box', 'nekoray', 'v2rayN', 'xray')

    $push = {
        param([string]$Value, $Seen, $List)
        if (-not $Value) { return }
        $Value = $Value.Trim()
        if (-not $Value) { return }
        if ($Value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $Value = 'http://' + $Value }
        if (-not $Seen.ContainsKey($Value)) {
            $Seen[$Value] = $true
            $List.Add($Value)
        }
    }

    if ($script:telegramProxy) { & $push $script:telegramProxy $seen $result }
    & $push $env:HTTPS_PROXY $seen $result
    & $push $env:HTTP_PROXY $seen $result
    & $push $env:ALL_PROXY $seen $result

    try {
        $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($ie.ProxyEnable -eq 1 -and $ie.ProxyServer) {
            foreach ($part in ([string]$ie.ProxyServer -split ';')) {
                & $push ($part -replace '^[^=]*=', '') $seen $result
            }
        }
    } catch { }

    $commonPorts = @(7890, 7891, 7892, 7897, 7899, 1080, 10808, 10809, 2080, 8889, 20171)
    $listenPorts = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort)
    foreach ($port in $commonPorts) {
        if ($listenPorts -contains $port) { & $push ('http://127.0.0.1:' + $port) $seen $result }
    }
    $pids = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName } | Select-Object -ExpandProperty Id)
    if ($pids.Count -gt 0) {
        $conns = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $pids -contains $_.OwningProcess })
        foreach ($conn in $conns) {
            if ($conn.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::1', '::')) {
                & $push ('http://127.0.0.1:' + $conn.LocalPort) $seen $result
            }
        }
    }
    return $result
}

function Send-TelegramMessage {
    param([string]$Token, [string]$ChatId, [string]$Text, [string[]]$ProxyList)
    $body = @{ chat_id = $ChatId; text = $Text; disable_web_page_preview = $true } | ConvertTo-Json -Depth 3
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $uri = "https://api.telegram.org/bot$Token/sendMessage"

    $routeCache = Join-Path $script:scriptDir 'telegram-route.txt'
    $routes = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $addRoute = {
        param([string]$Value, $Seen, $List)
        if ($null -eq $Value) { return }
        if (-not $Seen.ContainsKey($Value)) { $Seen[$Value] = $true; $List.Add($Value) }
    }
    if (Test-Path -LiteralPath $routeCache) {
        $cached = (Get-Content -LiteralPath $routeCache -Raw).Trim()
        if ($cached) { & $addRoute $cached $seen $routes }
    }
    foreach ($item in @($ProxyList)) { if ($item) { & $addRoute $item $seen $routes } }
    if (-not $seen.ContainsKey('')) { $seen[''] = $true; $routes.Add('') }

    $lastError = ''
    foreach ($route in $routes) {
        try {
            $req = @{
                Uri = $uri
                Method = 'Post'
                ContentType = 'application/json; charset=utf-8'
                Body = $bytes
                TimeoutSec = 8
            }
            if ($route) { $req['Proxy'] = $route }
            Invoke-RestMethod @req | Out-Null
            [IO.File]::WriteAllText($routeCache, $route, (New-Object Text.UTF8Encoding($false)))
            if ($route) { Write-Log "Telegram 通知已发送（经代理 $route）" }
            else { Write-Log 'Telegram 通知已发送（直连）' }
            return $true
        } catch {
            $lastError = $_.Exception.Message
        }
    }
    Write-Log ("Telegram 通知发送失败：" + $lastError)
    return $false
}

function Send-WorkerReport {
    param([string]$Text, [string]$ChatId)
    if (-not $notifyUrl) { return $false }
    if (-not (Test-Path -LiteralPath $notifySecretFile)) { return $false }
    $secret = (Get-Content -LiteralPath $notifySecretFile -Raw).Trim()
    if (-not $secret) { return $false }

    $body = @{ chatId = $ChatId; text = $Text } | ConvertTo-Json -Depth 3
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $uri = $notifyUrl.TrimEnd('/') + '/notify'

    $routes = New-Object System.Collections.Generic.List[string]
    $routes.Add('')
    $added = 0
    foreach ($candidate in @(Get-LocalProxyCandidates)) {
        if ($added -ge 3) { break }
        $routes.Add($candidate)
        $added += 1
    }

    $lastError = ''
    foreach ($route in $routes) {
        try {
            $request = @{
                Uri = $uri
                Method = 'Post'
                Headers = @{ 'X-Notify-Secret' = $secret }
                ContentType = 'application/json; charset=utf-8'
                Body = $bytes
                TimeoutSec = 8
            }
            if ($route) { $request['Proxy'] = $route }
            Invoke-RestMethod @request | Out-Null
            if ($route) { Write-Log ("汇报已通过 Worker 发送（代理 $route）") }
            else { Write-Log '汇报已通过 Worker 发送（直连）' }
            return $true
        } catch {
            $lastError = $_.Exception.Message
        }
    }
    Write-Log ('Worker 汇报失败：' + $lastError)
    return $false
}

function Queue-RepoReport {
    param([string]$Text, [string]$ChatId)
    try {
        $file = Get-RepoFile -Path $queuePath
        $items = @()
        if ($file.Text -and $file.Text.Trim() -ne '') {
            try {
                $existing = $file.Text | ConvertFrom-Json
                $existingItems = Get-RawValue $existing 'items'
                if ($existingItems) { $items = @($existingItems) }
            } catch { $items = @() }
        }
        $entry = [ordered]@{
            id = [guid]::NewGuid().ToString('N')
            chatId = $ChatId
            text = $Text
            at = (Get-Date).ToString('s')
        }
        $items = @($items) + @($entry)
        if ($items.Count -gt 10) { $items = @($items | Select-Object -Last 10) }
        $json = [ordered]@{ items = $items } | ConvertTo-Json -Depth 6
        Set-RepoFile -Path $queuePath -Text ($json + "`n") -Sha $file.Sha -Message 'agent: queue telegram report'
        Write-Log '汇报已写入 GitHub 队列，等待 Worker 定时转发'
        return $true
    } catch {
        Write-Log ('写入 GitHub 汇报队列失败：' + $_.Exception.Message)
        return $false
    }
}

function Send-Report {
    param([string]$Text, [string]$ChatId = '')
    if (-not $ChatId) { $ChatId = $telegramChatId }
    if (-not $ChatId) { return $false }
    if (Send-WorkerReport -Text $Text -ChatId $ChatId) { return $true }
    if (Queue-RepoReport -Text $Text -ChatId $ChatId) { return $true }
    if (-not (Test-Path -LiteralPath $telegramTokenFile)) { return $false }
    $token = (Get-Content -LiteralPath $telegramTokenFile -Raw).Trim()
    return Send-TelegramMessage -Token $token -ChatId $ChatId -Text $Text -ProxyList (Get-LocalProxyCandidates)
}

function Save-PendingReport {
    param([string]$Text)
    $dir = Join-Path $script:scriptDir 'pending-reports'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $name = 'report-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $existing = @(Get-ChildItem -LiteralPath $dir -Filter 'report-*.txt' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($existing.Count -gt 20) {
        $existing | Select-Object -First ($existing.Count - 20) | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
    [IO.File]::WriteAllText((Join-Path $dir $name), $Text, (New-Object Text.UTF8Encoding($false)))
    Write-Log ('汇报已暂存：' + $name)
}

function Send-PendingReports {
    $dir = Join-Path $script:scriptDir 'pending-reports'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter 'report-*.txt' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 5)
    if ($files.Count -eq 0) { return }
    Write-Log ('有 {0} 条历史汇报待补发' -f $files.Count)
    foreach ($file in $files) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if (Send-Report $text) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            Write-Log ('补发成功：' + $file.Name)
        } else {
            Write-Log '补发失败，保留到下一轮'
            return
        }
    }
}

function ConvertTo-RepoPath {
    param([string]$Path)
    return (($Path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}

function Get-RepoFile {
    param([string]$Path)
    $url = 'https://api.github.com/repos/{0}/contents/{1}?ref={2}' -f $repo, (ConvertTo-RepoPath $Path), $branch
    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'cfdata-agent'
    }
    try {
        $data = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 30
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 404) { return [pscustomobject]@{ Text = ''; Sha = '' } }
        throw
    }
    $text = ''
    if ($data.content) {
        $clean = ([string]$data.content) -replace '\s', ''
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($clean))
    }
    return [pscustomobject]@{ Text = $text; Sha = [string]$data.sha }
}

function Set-RepoFile {
    param([string]$Path, [string]$Text, [string]$Sha, [string]$Message)
    $url = 'https://api.github.com/repos/{0}/contents/{1}' -f $repo, (ConvertTo-RepoPath $Path)
    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'cfdata-agent'
    }
    $payload = [ordered]@{
        message = $Message
        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
        branch = $branch
    }
    if ($Sha) { $payload['sha'] = $Sha }
    $body = $payload | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri $url -Headers $headers -Method Put -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 30 | Out-Null
}

function Complete-RetestRequest {
    param([string]$Id, [string]$Status)
    if (-not $Id) { return }
    try {
        $file = Get-RepoFile -Path $commandPath
        $currentId = ''
        if ($file.Text -and $file.Text.Trim() -ne '') {
            try { $currentId = [string](Get-RawValue ($file.Text | ConvertFrom-Json) 'id') } catch { $currentId = '' }
        }
        if ($currentId -and $currentId -ne $Id) {
            Write-Log ("检测到更新的重测请求 {0}，保留不覆盖" -f $currentId)
            return
        }
        $body = ([ordered]@{ id = $Id; status = $Status; doneAt = (Get-Date).ToString('s') } | ConvertTo-Json -Compress)
        Set-RepoFile -Path $commandPath -Text ($body + "`n") -Sha $file.Sha -Message ("tg: retest {0} {1}" -f $Id, $Status)
        Write-Log ("重测请求 {0} 已标记为 {1}" -f $Id, $Status)
    } catch {
        Write-Log ('标记重测请求失败：' + $_.Exception.Message)
    }
}

function Save-AgentState {
    param([string]$Hash, [string]$Source, [string]$RequestId)
    $object = [ordered]@{}
    if ($state) {
        foreach ($property in $state.PSObject.Properties) { $object[$property.Name] = $property.Value }
    }
    if ($Hash) {
        $object['hash'] = $Hash
        $object['lastRun'] = (Get-Date).ToString('s')
    }
    if ($Source) { $object['source'] = $Source }
    if ($RequestId) {
        $object['lastRequestId'] = $RequestId
        $object['lastRetestAt'] = (Get-Date).ToString('s')
    }
    [IO.File]::WriteAllText($stateFile, ($object | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}

if (-not (Test-Path -LiteralPath $Config)) {
    throw "找不到配置文件：$Config（先复制 agent.config.example.json 为 agent.config.json 再修改）"
}

$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json

$repo = Get-Str $cfg 'repo' 'xiaokuixing/cfdata-results'
$branch = Get-Str $cfg 'branch' 'main'
$inboxPath = Get-Str $cfg 'inboxPath' 'shared-ips.txt'
$commandPath = Get-Str $cfg 'commandPath' 'agent/retest-request.json'
$uploadPath = Get-Str $cfg 'uploadPath' 'results.txt'
$sourceMode = (Get-Str $cfg 'sourceMode' 'api').ToLowerInvariant()
$exe = [Environment]::ExpandEnvironmentVariables((Get-Str $cfg 'cfdataExe' ''))
$tokenFile = [Environment]::ExpandEnvironmentVariables((Get-Str $cfg 'tokenFile' '%USERPROFILE%\.cfdata-results\gh-token.txt'))
$timeoutMinutes = [int](Get-Num $cfg 'timeoutMinutes' 30)
$proxy = Get-Str $cfg 'proxy' ''
$sourceUrl = Get-Str $cfg 'sourceUrl' ''
if (-not $sourceUrl) {
    $sourceUrl = "https://raw.githubusercontent.com/$repo/$branch/$inboxPath"
}

$notify = (Get-Str $cfg 'notify' 'true').ToLowerInvariant() -ne 'false'
$telegramTokenFile = [Environment]::ExpandEnvironmentVariables((Get-Str $cfg 'telegramTokenFile' '%USERPROFILE%\.cfdata-results\bot-token.txt'))
$telegramChatId = Get-Str $cfg 'telegramChatId' ''
$telegramProxy = Get-Str $cfg 'telegramProxy' ''
$notifyUrl = Get-Str $cfg 'notifyUrl' ''
$notifySecretFile = [Environment]::ExpandEnvironmentVariables((Get-Str $cfg 'notifySecretFile' '%USERPROFILE%\.cfdata-results\notify-secret.txt'))
$queuePath = Get-Str $cfg 'queuePath' 'agent/report-queue.json'
$params = Get-RawValue $cfg 'params'

$argList = New-Object 'System.Collections.Generic.List[string]'
$argList.Add('-cli')
Add-Arg $argList '-mode' 'nsb'
Add-Arg $argList '-nsbthreads' (Get-Num $params 'threads' 100)
Add-Arg $argList '-nsbspeedtest' (Get-Num $params 'speedThreads' 1)
Add-Arg $argList '-nsbspeedmin' (Format-Number (Get-Num $params 'speedMin' 8.0))
Add-Arg $argList '-nsbspeedlimit' (Get-Num $params 'speedLimit' 10)
Add-Arg $argList '-nsbresultlimit' (Get-Num $params 'resultLimit' 500)
Add-Arg $argList '-nsbdelay' (Get-Num $params 'delay' 0)
Add-BoolArg $argList '-nsbtls' (Get-RawValue $params 'tls')
Add-BoolArg $argList '-relink' (Get-RawValue $params 'relink')
$relinkHost = Get-Str $params 'relinkHost' ''
if ($relinkHost) { Add-Arg $argList '-relinkhost' $relinkHost }

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
    if ($sourceMode -eq 'api') {
        Write-Host "来源:      GitHub API / $repo / $branch / $inboxPath"
    } else {
        Write-Host "来源:      $sourceUrl"
    }
    Write-Host "上传到:    $repo / $branch / $uploadPath"
    Write-Host "token:     $tokenFile"
    Write-Host ""
    Write-Host "命令（运行时会把来源下载到临时文件）："
    $preview = @($argList)
    if ($sourceMode -eq 'api') {
        $preview += '-nsbfile'
        $preview += '<temp>\source-ips.txt'
    } else {
        $preview += '-nsbsourceurl'
        $preview += $sourceUrl
    }
    Write-Host ("  `"$exe`" " + ((Quote-Args $preview) -join ' '))
    exit 0
}

if (-not (Test-Path -LiteralPath $exe)) {
    throw "cfdata 可执行文件不存在：$exe（修改 agent.config.json 里的 cfdataExe）"
}
if (-not (Test-Path -LiteralPath $tokenFile)) {
    throw "GitHub token 文件不存在：$tokenFile"
}

$token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()

$mutex = New-Object System.Threading.Mutex($false, 'Local\cfdata-tg-agent')
if (-not $mutex.WaitOne(0)) {
    Write-Log '上一轮还在运行，跳过本轮'
    exit 0
}
if ($notify) { try { Send-PendingReports } catch { Write-Log ('补发汇报出错：' + $_.Exception.Message) } }


$tempDir = Join-Path $env:TEMP ('cfdata-agent-' + [guid]::NewGuid().ToString('N'))
$stateFile = Join-Path $scriptDir 'state.json'
$exitCode = 0

$state = $null
if (Test-Path -LiteralPath $stateFile) {
    try { $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
}

$reportChatId = $telegramChatId
$retestRequestId = ''

if (-not $SourceFile) {
    try {
        $requestFile = Get-RepoFile -Path $commandPath
        if ($requestFile.Text -and $requestFile.Text.Trim() -ne '') {
            $request = $null
            try { $request = $requestFile.Text | ConvertFrom-Json } catch { $request = $null }
            if ($null -eq $request) {
                Write-Log '重测请求不是合法 JSON，忽略'
            } else {
                $requestId = [string](Get-RawValue $request 'id')
                $requestStatus = [string](Get-RawValue $request 'status')
                $lastRequestId = [string](Get-RawValue $state 'lastRequestId')
                if ($requestStatus -eq 'done') {
                    # 已处理过的请求，不再重复
                } elseif (-not $requestId -or $requestId -eq $lastRequestId) {
                    # 同一个请求，已在跑或已跑完
                } else {
                    $requestEndpoints = New-Object System.Collections.Generic.List[string]
                    foreach ($item in @(Get-RawValue $request 'endpoints')) {
                        $endpoint = ([string]$item).Trim()
                        if ($endpoint) { $requestEndpoints.Add($endpoint) }
                    }
                    if ($requestEndpoints.Count -eq 0) {
                        Write-Log ("重测请求 {0} 里没有可用 IP，忽略" -f $requestId)
                    } else {
                        $retestRequestId = $requestId
                        $requestChatId = [string](Get-RawValue $request 'chatId')
                        if ($requestChatId) { $reportChatId = $requestChatId }
                        $SourceFile = Join-Path $env:TEMP ('cfdata-request-{0}.txt' -f ($requestId -replace '[^0-9A-Za-z_-]', ''))
                        [IO.File]::WriteAllText($SourceFile, (($requestEndpoints -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
                        Write-Log ("收到 Telegram 重测请求 {0}：{1} 个 IP，汇报到 {2}" -f $requestId, $requestEndpoints.Count, $reportChatId)
                    }
                }
            }
        }
    } catch {
        Write-Log ('检查重测请求失败：' + $_.Exception.Message)
    }
}

try {
    if ($SourceFile) {
        $uri = $SourceFile
        if (-not (Test-Path -LiteralPath $SourceFile)) { throw "来源文件不存在：$SourceFile" }
        Write-Log "使用本地来源文件：$SourceFile"
    } elseif ($sourceMode -eq 'api') {
        $uri = "https://api.github.com/repos/$repo/contents/${inboxPath}?ref=${branch}"
        $headers = @{
            Authorization = "Bearer $token"
            Accept = 'application/vnd.github.raw'
            'User-Agent' = 'cfdata-agent'
        }
    } else {
        $uri = $sourceUrl
        $headers = @{ 'User-Agent' = 'cfdata-agent' }
    }

    Write-Log "检查来源：$uri"
    $content = ''
    if ($SourceFile) {
        $content = [IO.File]::ReadAllText($SourceFile)
    } else {
        try {
            $content = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 60
        } catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 404) {
                $content = ''
            } else {
                throw "下载来源失败（$status）：$($_.Exception.Message)"
            }
        }
    }
    if ($null -eq $content) { $content = '' }
    $content = ([string]$content).Replace("`r`n", "`n")

    $lines = @($content -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })
    if ($lines.Count -eq 0) {
        Write-Log '来源文件为空，跳过'
        exit 0
    }

    $hash = Get-ContentHash ($lines -join "`n")
    $lastHash = Get-RawValue $state 'hash'
    if (-not $Force -and -not $retestRequestId -and $lastHash -eq $hash) {
        Write-Log '来源没有变化，跳过'
        exit 0
    }

    Write-Log ("来源共 {0} 条，开始调用 cfdata" -f $lines.Count)

    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $runList = New-Object 'System.Collections.Generic.List[string]'
    $runList.AddRange($argList)
    if ($sourceMode -eq 'api') {
        $tempSourceFile = Join-Path $tempDir 'source-ips.txt'
        [IO.File]::WriteAllText($tempSourceFile, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
        $runList.Add('-nsbfile')
        $runList.Add($tempSourceFile)
    } else {
        $runList.Add('-nsbsourceurl')
        $runList.Add($sourceUrl)
    }

    $quoted = Quote-Args $runList
    $arguments = ($quoted -join ' ')

    $runStart = Get-Date
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
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
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

    $speedRows = @()
    foreach ($sm in [regex]::Matches($output, '(?m)^\[speed\]\s*(?:\[\d*/\d*\]\s*)?(\S+)\s+(.+?)\s*$')) {
        $addr = $sm.Groups[1].Value
        $speedText = $sm.Groups[2].Value.Trim()
        $speedValue = $null
        $vm = [regex]::Match($speedText, '([0-9]+(?:\.[0-9]+)?)\s*MB/s')
        if ($vm.Success) { $speedValue = [double]$vm.Groups[1].Value }
        if ($speedText.Length -gt 40) { $speedText = $speedText.Substring(0, 40) + '…' }
        $speedRows += [pscustomobject]@{ Addr = $addr; Text = $speedText; MB = $speedValue }
    }
    if ($speedRows.Count -gt 1) {
        $speedRows = @($speedRows | Sort-Object -Property @{ Expression = { if ($null -eq $_.MB) { -1 } else { $_.MB } }; Descending = $true })
    }

    $summaryInput = $lines.Count
    $summaryRelink = $lines.Count
    $summarySpeed = 0
    $summaryRows = 0
    $m = [regex]::Match($output, '输入\s*\d+\s*条记录[，,]\s*解析为\s*(\d+)\s*个地址')
    if ($m.Success) { $summaryInput = [int]$m.Groups[1].Value }
    $m = [regex]::Match($output, '链路复验完成：可用\s*(\d+)')
    if ($m.Success) { $summaryRelink = [int]$m.Groups[1].Value }
    $m = [regex]::Match($output, '开始测速：(\d+)\s*条记录')
    if ($m.Success) { $summarySpeed = [int]$m.Groups[1].Value }

    $rowMatches = [regex]::Matches($output, 'cfdata-run\.txt\s*\((\d+)\s*rows')
    if ($rowMatches.Count -gt 0) {
        $summaryRows = [int]$rowMatches[$rowMatches.Count - 1].Groups[1].Value
    }
    $uploadMatch = [regex]::Match($output, '\[github\]\s+uploaded\s+(\S+)')
    $summaryUploaded = $uploadMatch.Success

    if ($notify -and $reportChatId -and (Test-Path -LiteralPath $telegramTokenFile)) {
        $pDelay = Get-Num $params 'delay' 0
        $pSpeedMin = Get-Num $params 'speedMin' 0.1
        $pSpeedThreads = Get-Num $params 'speedThreads' 0
        $elapsed = (Get-Date) - $runStart
        if ($elapsed.TotalMinutes -ge 1) {
            $durationText = '{0} 分 {1} 秒' -f [int][math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
        } else {
            $durationText = '{0} 秒' -f [int]$elapsed.TotalSeconds
        }

        $msg = @()
        if ($cfdataExit -ne 0) { $msg += ('⚠️ cfdata 异常退出，退出码 {0}' -f $cfdataExit) }
        $headerText = '📊 本轮测速完成 · ' + (Get-Date -Format 'MM-dd HH:mm')
        if ($retestRequestId) { $headerText = '🔁 重测完成（来自 Telegram）· ' + (Get-Date -Format 'MM-dd HH:mm') }
        elseif ($SourceFile) { $headerText = '🔁 手动重测 · ' + (Get-Date -Format 'MM-dd HH:mm') }
        $msg += $headerText
        $msg += ('条件：延迟 ≤ {0}ms · 速度 ≥ {1}MB/s · 并发 {2}' -f (Format-Number $pDelay), (Format-Number $pSpeedMin), $pSpeedThreads)
        $msg += ''
        $msg += ('来源 {0} 个 → 链路可用 {1} 个 → 实际测速 {2} 个' -f $summaryInput, $summaryRelink, $summarySpeed)
        if ($output -match '链路复验后未发现可用 IP') {
            $msg += '链路复验后没有可用 IP（来源当前不通），未进入测速。'
        } elseif ($summaryRows -gt 0) {
            if ($summaryUploaded) {
                $msg += ('合格 {0} 个 · 已上传 {0} 个到 {1}' -f $summaryRows, $uploadPath)
            } else {
                $msg += ('合格 {0} 个 · 但上传未确认，请查看日志' -f $summaryRows)
            }
        } else {
            $msg += '合格 0 个 · 未上传（本轮没有达到门槛的 IP）'
        }
        $msg += ('耗时 ' + $durationText)

        if ($speedRows.Count -gt 0) {
            $msg += ''
            $listLimit = 60
            foreach ($row in ($speedRows | Select-Object -First $listLimit)) {
                $mark = '❌'
                if ($null -ne $row.MB -and [double]$row.MB -ge [double]$pSpeedMin) { $mark = '✅' }
                $msg += ('{0} {1} — {2}' -f $mark, $row.Addr, $row.Text)
            }
            if ($speedRows.Count -gt $listLimit) {
                $msg += ('… 另有 {0} 个未列出' -f ($speedRows.Count - $listLimit))
            }
        }

        if ($summaryRows -gt 0 -and $summaryUploaded) {
            $msg += ''
            $msg += ('https://github.com/{0}/blob/{1}/{2}' -f $repo, $branch, $uploadPath)
        }

        $msgText = ($msg -join "`n")
        if ($msgText.Length -gt 4000) { $msgText = $msgText.Substring(0, 4000) }
        if (Send-Report -Text $msgText -ChatId $reportChatId) {
            Write-Log '汇报已交付（Worker 直发或队列转发）'
        } else {
            Save-PendingReport $msgText
        }
    }

    if ($cfdataExit -ne 0) {
        Write-Log "cfdata 退出码 $cfdataExit，本轮不记录来源状态"
        $exitCode = 1
        if ($retestRequestId) {
            Complete-RetestRequest -Id $retestRequestId -Status 'failed'
            Save-AgentState -RequestId $retestRequestId
        }
    } else {
        if ($SourceFile -and -not $retestRequestId) {
            Write-Log '手动重测，不更新来源状态'
        } else {
            if ($retestRequestId) { Complete-RetestRequest -Id $retestRequestId -Status 'done' }
            if ($SourceFile) {
                Save-AgentState -RequestId $retestRequestId
            } else {
                Save-AgentState -Hash $hash -Source $uri -RequestId $retestRequestId
            }
        }
        Write-Log '本轮完成'
    }
} catch {
    Write-Log ("出错：" + $_.Exception.Message)
    $exitCode = 1
    if ($retestRequestId) {
        Complete-RetestRequest -Id $retestRequestId -Status 'failed'
        Save-AgentState -RequestId $retestRequestId
        if ($notify -and $reportChatId) {
            $failText = ('⚠️ 重测失败 · {0}' -f (Get-Date -Format 'MM-dd HH:mm')) + "`n" + $_.Exception.Message
            if ($failText.Length -gt 3500) { $failText = $failText.Substring(0, 3500) }
            if (-not (Send-Report -Text $failText -ChatId $reportChatId)) { Save-PendingReport $failText }
        }
    }
} finally {
    if ($retestRequestId -and $SourceFile -and (Test-Path -LiteralPath $SourceFile)) {
        Remove-Item -LiteralPath $SourceFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

exit $exitCode