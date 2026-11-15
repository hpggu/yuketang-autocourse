#requires -Version 5.1
<#
.SYNOPSIS
    雨课堂自动连播 v2.0.0 —— 通过 Chrome DevTools Protocol 控制浏览器。

.DESCRIPTION
    v1.x 用 Windows UI Automation 读页面，依赖浏览器把 DOM 暴露成无障碍树。
    新版 Edge / Chrome 只把「有语义」的节点暴露出来，播放器整块缺失，
    于是脚本永远找不到 xt_video_player，一启动就报「未找到包含播放器的窗口」。

    v2.0 改成 CDP：浏览器开一个调试端口，脚本用 WebSocket 在页面里执行 JS，
    直接读 <video> 的 currentTime / duration / paused，播完点目录里的下一节。

    好处：不抢鼠标、浏览器可以最小化、对窗口缩放和遮挡完全免疫。

.PARAMETER Port
    浏览器远程调试端口，默认 9222。

.PARAMETER PollSeconds
    轮询间隔（秒），最小 1。

.PARAMETER Once
    只报告一次当前状态就退出，不操作页面。

.PARAMETER NextNow
    立刻切到目录里的下一节视频，然后退出。

.PARAMETER UrlMatch
    用哪个关键字挑标签页，默认 yuketang。

.PARAMETER MaxVideos
    本次最多播放几节，0 表示不限制。

.PARAMETER MaxStuckPerLesson
    同一节卡住多少次后尝试跳到下一节。

.PARAMETER MaxStuckTotal
    全程卡住多少次后退出。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\AutoCourse.ps1 -Once
#>
param(
    [int]$Port = 9222,
    [int]$PollSeconds = 2,
    [switch]$Once,
    [switch]$NextNow,
    [string]$UrlMatch = 'yuketang',
    [int]$MaxVideos = 0,
    [int]$MaxStuckPerLesson = 20,
    [int]$MaxStuckTotal = 60,
    [double]$EndToleranceSeconds = 1.5,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:Version = '2.0.0'
$script:MutexName = 'Local\YuketangAutoCourse'
$script:StopMarker = Join-Path $PSScriptRoot 'STOP_AUTOCOURSE'
$script:LogDir = Join-Path $PSScriptRoot 'logs'
$script:LogPath = $null
$script:ExitCode = 0
$script:CdpId = 0

# ---------------------------------------------------------------- 日志

function Initialize-Log {
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    $name = 'autocourse-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $script:LogPath = Join-Path $script:LogDir $name
}

function Write-CourseLog {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'HH:mm:ss'
    if (-not $Quiet) { Write-Host ('[{0}] {1}' -f $stamp, $Message) }
    if ($script:LogPath) {
        try {
            $prefix = 'INFO'
            if ($Level -eq 'WARN') { $prefix = 'WARN' }
            if ($Level -eq 'ERROR') { $prefix = 'ERR ' }
            $text = '[{0}] {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $prefix, $Message
            Add-Content -LiteralPath $script:LogPath -Value $text -Encoding UTF8
        } catch { }
    }
}

# ---------------------------------------------------------------- CDP 基础设施

function Get-CdpPages {
    param([int]$Port)
    return @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 5 -ErrorAction Stop |
        Where-Object { $_.type -eq 'page' })
}

function Test-CdpPort {
    param([int]$Port)
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 3 -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Connect-CdpPage {
    param([string]$WsUrl)
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
    $task = $ws.ConnectAsync([Uri]$WsUrl, [System.Threading.CancellationToken]::None)
    if (-not $task.Wait(10000)) { throw 'WebSocket 连接超时' }
    return $ws
}

function Send-CdpRaw {
    param($Ws, [string]$Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $seg = [System.ArraySegment[byte]]::new($bytes)
    $task = $Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
    if (-not $task.Wait(10000)) { throw 'CDP 发送超时' }
}

function Receive-CdpRaw {
    param($Ws, [int]$TimeoutMs = 15000)
    $buf = New-Object byte[] 131072
    $seg = [System.ArraySegment[byte]]::new($buf)
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
        $task = $Ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
        if (-not $task.Wait($TimeoutMs)) { return $null }
        $res = $task.Result
        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
        if ($res.EndOfMessage) { break }
    }
    return $sb.ToString()
}

function Invoke-Cdp {
    param(
        $Ws,
        [string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutMs = 20000
    )
    $script:CdpId = $script:CdpId + 1
    $id = $script:CdpId
    $payload = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 8 -Compress
    Send-CdpRaw -Ws $Ws -Json $payload
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $raw = Receive-CdpRaw -Ws $Ws -TimeoutMs 8000
        if (-not $raw) { return $null }
        $obj = $null
        try { $obj = $raw | ConvertFrom-Json } catch { continue }
        if ($obj.id -eq $id) { return $obj }
    }
    return $null
}

function Invoke-Eval {
    param($Ws, [string]$Js, [int]$TimeoutMs = 20000)
    $resp = Invoke-Cdp -Ws $Ws -Method 'Runtime.evaluate' -Params @{
        expression    = $Js
        returnByValue = $true
        awaitPromise  = $true
    } -TimeoutMs $TimeoutMs
    if (-not $resp) { throw 'evaluate 没有返回' }
    if ($resp.error) { throw ('CDP 错误：' + ($resp.error | ConvertTo-Json -Compress)) }
    if ($resp.result.exceptionDetails) {
        $msg = $resp.result.exceptionDetails.text
        $detail = $resp.result.exceptionDetails.exception
        if ($detail -and $detail.description) { $msg = $detail.description }
        throw ('页面脚本异常：' + $msg)
    }
    return $resp.result.result.value
}

function Invoke-EvalJson {
    param($Ws, [string]$Js, [int]$TimeoutMs = 20000)
    $raw = Invoke-Eval -Ws $Ws -Js $Js -TimeoutMs $TimeoutMs
    if ($null -eq $raw) { return $null }
    if ($raw -is [string]) {
        try { return ($raw | ConvertFrom-Json) } catch { return $null }
    }
    return $raw
}

# ---------------------------------------------------------------- 页面脚本

function Get-StateScript {
    param([double]$Tolerance)
    $tol = $Tolerance.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    return @"
(() => {
  const tol = $tol;
  const v = document.querySelector('video');
  const active = document.querySelector('.leaf-item.is-active');
  const leaves = document.querySelectorAll('.leaf-item');
  const overlaySel = '[class*="question"],[class*="quiz"],[class*="exam"],[class*="modal"],[class*="dialog"],[class*="popup"]';
  let overlays = [];
  try {
    overlays = [...document.querySelectorAll(overlaySel)].filter(el => {
      const r = el.getBoundingClientRect();
      return r.width > 240 && r.height > 120 && el.offsetParent !== null;
    });
  } catch (e) { overlays = []; }
  const base = {
    url: location.href,
    title: document.title,
    activeLeaf: active ? String(active.innerText || '').replace(/\s+/g, ' ').trim() : null,
    leafCount: leaves.length,
    overlayCount: overlays.length,
    overlayPreview: overlays.slice(0, 3).map(el => String(el.className || '').slice(0, 50))
  };
  if (!v) { return JSON.stringify(Object.assign({ ok: false, reason: 'no-video' }, base)); }
  const d = v.duration;
  const cur = v.currentTime;
  const hasDur = isFinite(d) && d > 0;
  const ended = v.ended || (hasDur && d > 3 && cur >= d - tol);
  return JSON.stringify(Object.assign({
    ok: true,
    cur: Math.round(cur * 100) / 100,
    dur: hasDur ? Math.round(d * 100) / 100 : null,
    paused: v.paused,
    ended: ended,
    readyState: v.readyState,
    rate: v.playbackRate,
    muted: v.muted,
    videoW: v.clientWidth,
    videoH: v.clientHeight
  }, base));
})()
"@
}

$script:PlayJs = @'
(() => {
  const v = document.querySelector('video');
  if (!v) { return JSON.stringify({ ok: false, reason: 'no-video' }); }
  if (!v.paused) { return JSON.stringify({ ok: true, action: 'already-playing' }); }
  try {
    const p = v.play();
    if (p && typeof p.then === 'function') {
      return p.then(() => JSON.stringify({ ok: true, action: 'played' }))
              .catch(e => JSON.stringify({ ok: false, reason: String(e && e.name), message: String(e && e.message) }));
    }
    return JSON.stringify({ ok: true, action: v.paused ? 'still-paused' : 'played' });
  } catch (e) {
    return JSON.stringify({ ok: false, reason: 'throw', message: String(e && e.message) });
  }
})()
'@

$script:NextJs = @'
(() => {
  const leaves = [...document.querySelectorAll('.leaf-item')];
  const active = document.querySelector('.leaf-item.is-active');
  if (!leaves.length) { return JSON.stringify({ ok: false, reason: 'no-leaves' }); }
  const idx = active ? leaves.indexOf(active) : -1;
  const isVideo = el => /视频/.test(String(el.innerText || ''));
  let next = -1;
  for (let i = Math.max(idx, -1) + 1; i < leaves.length; i++) {
    if (isVideo(leaves[i])) { next = i; break; }
  }
  if (next < 0) { return JSON.stringify({ ok: false, reason: 'no-next', idx: idx, total: leaves.length }); }
  const el = leaves[next];
  const label = String(el.innerText || '').replace(/\s+/g, ' ').trim();
  try { el.scrollIntoView({ block: 'center', behavior: 'instant' }); } catch (e) { el.scrollIntoView(); }
  el.click();
  return JSON.stringify({ ok: true, index: next, label: label });
})()
'@

$script:RectJs = @'
(() => {
  const v = document.querySelector('video');
  if (!v) { return JSON.stringify({ ok: false }); }
  const r = v.getBoundingClientRect();
  return JSON.stringify({ ok: true, x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height });
})()
'@

# ---------------------------------------------------------------- 辅助

function Find-BrowserExe {
    $candidates = @(
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Format-Seconds {
    param($Value)
    if ($null -eq $Value) { return '--:--' }
    $span = [TimeSpan]::FromSeconds([double]$Value)
    if ($span.TotalHours -ge 1) { return $span.ToString('h\:mm\:ss') }
    return $span.ToString('m\:ss')
}

function Write-StateReport {
    param($State, [int]$Port)
    Write-Host ''
    Write-Host ('Version      : {0}' -f $script:Version)
    Write-Host ('Transport    : CDP / WebSocket (port {0})' -f $Port)
    Write-Host ('PageTitle    : {0}' -f $State.title)
    Write-Host ('PageUrl      : {0}' -f $State.url)
    Write-Host ('ActiveLeaf   : {0}' -f $State.activeLeaf)
    Write-Host ('LeafCount    : {0}' -f $State.leafCount)
    if ($State.ok) {
        Write-Host ('CurrentTime  : {0}' -f (Format-Seconds $State.cur))
        Write-Host ('Duration     : {0}' -f (Format-Seconds $State.dur))
        Write-Host ('IsPlaying    : {0}' -f (-not $State.paused))
        Write-Host ('IsComplete   : {0}' -f $State.ended)
        Write-Host ('ReadyState   : {0}' -f $State.readyState)
        Write-Host ('PlaybackRate : {0}' -f $State.rate)
        Write-Host ('VideoSize    : {0}x{1}' -f $State.videoW, $State.videoH)
    } else {
        Write-Host ('VideoState   : 没找到 <video>（{0}）' -f $State.reason)
    }
    Write-Host ('Overlays     : {0} {1}' -f $State.overlayCount, ($State.overlayPreview -join ' | '))
    Write-Host ''
}

function New-Session {
    param([int]$Port, [string]$Match)
    $pages = Get-CdpPages -Port $Port
    $hit = @($pages | Where-Object { $_.url -match $Match })
    if ($hit.Count -eq 0) {
        $urls = ($pages | ForEach-Object { '  ' + $_.url }) -join "`n"
        throw "没有找到匹配 '$Match' 的标签页。当前页面：`n$urls"
    }
    $ws = Connect-CdpPage -WsUrl $hit[0].webSocketDebuggerUrl
    return @{ Ws = $ws; Page = $hit[0] }
}

function Invoke-ClickVideoCenter {
    param($Ws)
    $rect = Invoke-EvalJson -Ws $Ws -Js $script:RectJs
    if (-not $rect -or -not $rect.ok -or $rect.w -le 0) { return $false }
    foreach ($type in @('mousePressed', 'mouseReleased')) {
        $resp = Invoke-Cdp -Ws $Ws -Method 'Input.dispatchMouseEvent' -Params @{
            type       = $type
            x          = [double]$rect.x
            y          = [double]$rect.y
            button     = 'left'
            clickCount = 1
        }
        if (-not $resp) { return $false }
    }
    return $true
}

function Invoke-ResumePlayback {
    param($Ws)
    $res = Invoke-EvalJson -Ws $Ws -Js $script:PlayJs
    if ($res -and $res.ok) {
        if ($res.action -eq 'played') { Write-CourseLog '已恢复播放。'; return $true }
        if ($res.action -eq 'already-playing') { return $true }
        if ($res.action -eq 'still-paused') {
            Write-CourseLog 'play() 调用了但仍在暂停，改点播放器中央。' 'WARN'
        }
    } else {
        $reason = 'unknown'
        if ($res) { $reason = $res.reason }
        Write-CourseLog ('play() 失败（{0}），改点播放器中央。' -f $reason) 'WARN'
    }
    if (Invoke-ClickVideoCenter -Ws $Ws) {
        Start-Sleep -Milliseconds 900
        $again = Invoke-EvalJson -Ws $Ws -Js $script:PlayJs
        if ($again -and $again.ok -and $again.action -ne 'still-paused') {
            Write-CourseLog '点击后开始播放。'
            return $true
        }
    }
    Write-CourseLog '仍然没能恢复播放，可能是随堂测验挡住了播放器。' 'WARN'
    return $false
}

function Invoke-GoNextVideo {
    param($Ws)
    $res = Invoke-EvalJson -Ws $Ws -Js $script:NextJs
    if (-not $res) { Write-CourseLog '切换下一节失败：页面没有回应。' 'WARN'; return $false }
    if (-not $res.ok) {
        Write-CourseLog ('没有找到后面的视频节点（{0}）。' -f $res.reason) 'WARN'
        return $false
    }
    Write-CourseLog ('点到下一节：{0}' -f $res.label)
    return $true
}

function Start-MainLoop {
    param([hashtable]$Session, [int]$Port)

    $ws = $Session.Ws
    $videoDone = 0
    $stuckPerLesson = 0
    $stuckTotal = 0
    $lastCur = -1.0
    $lastLesson = $null

    while ($true) {
        if (Test-Path -LiteralPath $script:StopMarker) {
            Write-CourseLog '检测到停止标记，退出。'
            break
        }

        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-CourseLog 'WebSocket 断开，2 秒后重连……' 'WARN'
            Start-Sleep -Seconds 2
            try {
                $Session = New-Session -Port $Port -Match $UrlMatch
                $ws = $Session.Ws
                Write-CourseLog '重连成功。'
            } catch {
                Write-CourseLog ('重连失败：' + $_.Exception.Message) 'ERROR'
                $script:ExitCode = 1
                break
            }
            continue
        }

        $state = $null
        try {
            $state = Invoke-EvalJson -Ws $ws -Js (Get-StateScript -Tolerance $EndToleranceSeconds)
        } catch {
            Write-CourseLog ('读取页面状态失败：' + $_.Exception.Message) 'WARN'
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        if (-not $state) { Start-Sleep -Seconds $PollSeconds; continue }

        if (-not $state.ok) {
            Write-CourseLog '当前页面还没有 <video> 元素，等播放器加载……' 'WARN'
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        if ($state.overlayCount -gt 0) {
            Write-CourseLog ('页面上有 {0} 个疑似弹窗（{1}）。如果是随堂测验，需要手动处理。' -f $state.overlayCount, ($state.overlayPreview -join ' | ')) 'WARN'
        }

        if ($state.activeLeaf -ne $lastLesson) {
            $lastLesson = $state.activeLeaf
            $stuckPerLesson = 0
            $lastCur = -1.0
            Write-CourseLog ('当前小节：{0}' -f $state.activeLeaf)
        }

        if ($state.ended) {
            Write-CourseLog ('本节播完（{0} / {1}），3 秒后切下一节。' -f (Format-Seconds $state.cur), (Format-Seconds $state.dur))
            Start-Sleep -Seconds 3
            if (-not (Invoke-GoNextVideo -Ws $ws)) {
                Write-CourseLog '目录里没有后续视频，自动连播结束。'
                break
            }
            Start-Sleep -Seconds 4
            $videoDone++
            if ($MaxVideos -gt 0 -and $videoDone -ge $MaxVideos) {
                Write-CourseLog ('已播 {0} 节，达到 -MaxVideos 上限，退出。' -f $videoDone)
                break
            }
            $lastCur = -1.0
            continue
        }

        if ($state.paused) {
            Write-CourseLog ('暂停中（{0} / {1}），尝试恢复播放。' -f (Format-Seconds $state.cur), (Format-Seconds $state.dur))
            [void](Invoke-ResumePlayback -Ws $ws)
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        if ([Math]::Abs($state.cur - $lastCur) -lt 0.05) {
            $stuckPerLesson++
            $stuckTotal++
            Write-CourseLog ('播放时间 {0} 没推进（本节第 {1} 次 / 累计 {2} 次）。' -f (Format-Seconds $state.cur), $stuckPerLesson, $stuckTotal) 'WARN'

            if ($stuckPerLesson -eq 3) {
                Write-CourseLog '点一下播放器中央唤醒播放。' 'WARN'
                [void](Invoke-ClickVideoCenter -Ws $ws)
            }

            if ($stuckPerLesson -ge $MaxStuckPerLesson) {
                Write-CourseLog ('本节卡住 {0} 次，强制切下一节。' -f $stuckPerLesson) 'WARN'
                if (-not (Invoke-GoNextVideo -Ws $ws)) {
                    Write-CourseLog '没有后续视频，退出。' 'WARN'
                    break
                }
                Start-Sleep -Seconds 4
                $stuckPerLesson = 0
                $lastCur = -1.0
                continue
            }

            if ($stuckTotal -ge $MaxStuckTotal) {
                Write-CourseLog ('累计卡住 {0} 次，放弃。' -f $stuckTotal) 'ERROR'
                $script:ExitCode = 1
                break
            }
        } else {
            $stuckPerLesson = 0
        }

        $lastCur = $state.cur
        Start-Sleep -Seconds $PollSeconds
    }
}

# ---------------------------------------------------------------- 入口

Initialize-Log
Write-CourseLog ('雨课堂自动连播 v{0} 启动（CDP 模式）' -f $script:Version)
Write-CourseLog ('日志文件：{0}' -f $script:LogPath)

if (-not (Test-CdpPort -Port $Port)) {
    Write-CourseLog ("端口 {0} 上没有可用的调试接口，脚本连不上浏览器。" -f $Port) 'WARN'
    $exe = Find-BrowserExe
    Write-CourseLog '请完全退出浏览器后，用下面的命令重新打开（或直接双击 启动刷课.cmd）：' 'WARN'
    Write-CourseLog ("  `"{0}`" --remote-debugging-port={1}" -f $exe, $Port) 'WARN'
    exit 1
}

$session = $null
try {
    try {
        $session = New-Session -Port $Port -Match $UrlMatch
    } catch {
        Write-CourseLog ($_.Exception.Message) 'ERROR'
        exit 1
    }
    Write-CourseLog ('已连接页面：{0}' -f $session.Page.title)

    if ($Once -or $NextNow) {
        $state = Invoke-EvalJson -Ws $session.Ws -Js (Get-StateScript -Tolerance $EndToleranceSeconds)
        if (-not $state) {
            Write-CourseLog '读取状态失败。' 'ERROR'
            exit 1
        }
        Write-StateReport -State $state -Port $Port
        if ($NextNow) {
            if (Invoke-GoNextVideo -Ws $session.Ws) { $script:ExitCode = 0 } else { $script:ExitCode = 1 }
        }
        exit $script:ExitCode
    }

    $mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
        if (-not $acquired) {
            Write-CourseLog '已经有一个实例在跑（互斥量被占用）。' 'ERROR'
            exit 1
        }
        if (Test-Path -LiteralPath $script:StopMarker) {
            Remove-Item -LiteralPath $script:StopMarker -Force -ErrorAction SilentlyContinue
        }
        Write-CourseLog '已接管。停止：双击 停止自动连播.cmd，或本窗口按 Ctrl+C。'
        Start-MainLoop -Session $session -Port $Port
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
        if (Test-Path -LiteralPath $script:StopMarker) {
            Remove-Item -LiteralPath $script:StopMarker -Force -ErrorAction SilentlyContinue
        }
        if ($session -and $session.Ws) { try { $session.Ws.Dispose() } catch { } }
        Write-CourseLog ('结束，退出码 {0}。' -f $script:ExitCode)
    }
} finally {
    if ($session -and $session.Ws) { try { $session.Ws.Dispose() } catch { } }
}

exit $script:ExitCode
