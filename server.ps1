# ============================================================
#  端口实时监控 —— 本地服务端
#
#  零依赖：Windows 自带的 PowerShell 直接跑，不需要安装 Node / Python 等任何东西。
#  用法：双击「启动.cmd」，或在本目录执行
#        powershell -ExecutionPolicy Bypass -File server.ps1
# ============================================================

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$htmlPath = Join-Path $root 'index.html'
$TOTAL    = 65536

# ---------------------------------------------------------- 选一个能用的端口
$listener = $null
$port     = 0
foreach ($p in 8777..8790) {
    try {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
        $l.Start()
        $listener = $l
        $port     = $p
        break
    } catch { }
}
if ($null -eq $listener) {
    Write-Host '8777-8790 端口全被占用了，无法启动。' -ForegroundColor Red
    Read-Host '按回车退出'
    exit 1
}

# ---------------------------------------------------------- 进程名缓存
# PID -> 进程名。名字基本不变，15 秒刷一次，省掉每次扫描都调 tasklist。
$script:pidNames = @{}
$script:namesAt  = [datetime]::MinValue

function Update-PidNames {
    $map = @{}
    try {
        foreach ($line in (& tasklist /FO CSV /NH 2>$null)) {
            if ($line -match '^"([^"]+)","(\d+)"') { $map[$Matches[2]] = $Matches[1] }
        }
    } catch { }
    $script:pidNames = $map
    $script:namesAt  = Get-Date
}

# ---------------------------------------------------------- 端口扫描
# netstat -ano 的行格式：
#   TCP   0.0.0.0:135   0.0.0.0:0    LISTENING    1144
#   UDP   0.0.0.0:500   *:*                        1144
# 第 4 段（状态）对 UDP 不存在，所以做成可选组。
# 开头 (?m) 是多行模式，必须有：否则 ^ $ 只匹配整串首尾，一行都匹配不到。
$netstatRx = [regex]'(?m)^\s*(TCP|UDP)\s+(\S+)\s+(\S+)(?:\s+(\S+))?\s+(\d+)\s*$'

# kind: 1 = 监听中/服务端(TCP LISTENING 或 UDP 已绑定)   2 = 连接占用(临时端口)
function Get-PortsJson {
    if (((Get-Date) - $script:namesAt).TotalSeconds -gt 15) { Update-PidNames }

    $agg  = @{}
    $text = ((& netstat -ano) -join "`n")

    foreach ($m in $netstatRx.Matches($text)) {
        $proto = $m.Groups[1].Value
        $local = $m.Groups[2].Value
        $state = if ($proto -eq 'UDP') { 'UDP' } else { $m.Groups[4].Value }
        # 注意：不能用 $pid —— 那是 PowerShell 的只读自动变量（当前进程 ID），赋值会抛异常
        $procId = $m.Groups[5].Value

        # 兼容 [::]:135 这类 IPv6 写法，取最后一个冒号后面的数字
        $i = $local.LastIndexOf(':')
        if ($i -lt 0) { continue }
        $n = 0
        if (-not [int]::TryParse($local.Substring($i + 1), [ref]$n)) { continue }
        if ($n -lt 0 -or $n -gt 65535) { continue }

        $kind = if ($proto -eq 'UDP' -or $state -eq 'LISTENING') { 1 } else { 2 }

        if (-not $agg.ContainsKey($n)) {
            $agg[$n] = @{
                kind   = 2
                pids   = [System.Collections.Generic.HashSet[string]]::new()
                states = [System.Collections.Generic.HashSet[string]]::new()
            }
        }
        $e = $agg[$n]
        if ($kind -eq 1) { $e.kind = 1 }
        [void]$e.pids.Add($procId)
        [void]$e.states.Add($state)
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{"t":').Append([long]([DateTime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
    [void]$sb.Append(',"total":').Append($TOTAL).Append(',"rows":[')

    $first = $true
    foreach ($n in ($agg.Keys | Sort-Object)) {
        $e = $agg[$n]

        $names = @()
        foreach ($procId in $e.pids) {
            # PID 0 = 连接已关闭但端口还在 TIME_WAIT 里没释放，没有真正的属主进程
            if ($procId -eq '0') { $names += '（无进程 / TIME_WAIT 残留）' }
            elseif ($script:pidNames.ContainsKey($procId)) { $names += $script:pidNames[$procId] }
            else { $names += "PID $procId" }
        }
        $nameStr  = (($names | Sort-Object -Unique) -join '、')
        $stateStr = (($e.states | Sort-Object) -join '/')

        if (-not $first) { [void]$sb.Append(',') }
        $first = $false
        [void]$sb.Append('[').Append($n).Append(',').Append($e.kind).Append(',"')
        [void]$sb.Append($nameStr.Replace('\', '\\').Replace('"', '\"')).Append('","')
        [void]$sb.Append($stateStr).Append('"]')
    }
    [void]$sb.Append(']}')
    return $sb.ToString()
}

# ---------------------------------------------------------- HTTP
$htmlBytes = $null
if (Test-Path $htmlPath) { $htmlBytes = [System.IO.File]::ReadAllBytes($htmlPath) }

function Send-Bytes {
    param($stream, $status, $ctype, [byte[]]$body)
    $head = "HTTP/1.1 $status`r`nContent-Type: $ctype`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length)
    if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
    $stream.Flush()
}

function Send-Text {
    param($stream, $status, $text)
    Send-Bytes $stream $status 'text/plain; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes($text))
}

$url = "http://127.0.0.1:$port"
Write-Host ''
Write-Host '  端口实时监控已启动' -ForegroundColor Green
Write-Host "  地址 : $url"
Write-Host '  停止 : 关掉本窗口，或按 Ctrl+C'
Write-Host ''

Start-Process $url

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 5000
        $client.SendTimeout    = 5000

        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)

        $reqLine = $reader.ReadLine()
        if ([string]::IsNullOrEmpty($reqLine)) { continue }
        while ($true) {                                   # 读完请求头
            $h = $reader.ReadLine()
            if ([string]::IsNullOrEmpty($h)) { break }
        }

        $parts = $reqLine.Split(' ')
        $path  = if ($parts.Length -ge 2) { $parts[1].Split('?')[0] } else { '/' }

        if ($path -eq '/' -or $path -eq '/index.html') {
            if ($null -ne $htmlBytes) {
                Send-Bytes $stream '200 OK' 'text/html; charset=utf-8' $htmlBytes
            } else {
                Send-Text $stream '500 Internal Server Error' '找不到 index.html，请确认它和 server.ps1 在同一个文件夹里。'
            }
        }
        elseif ($path -eq '/api/ports') {
            Send-Bytes $stream '200 OK' 'application/json; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes((Get-PortsJson)))
        }
        else {
            Send-Text $stream '404 Not Found' 'not found'
        }
    } catch { }
    finally {
        if ($null -ne $client) {
            # 先发 FIN 再关，避免响应还没发完就 RST 被截断
            try { $client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch { }
            try { $client.Close() } catch { }
        }
    }
}
