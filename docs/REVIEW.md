# 代码评审与改进路线

评审对象：`src/AutoCourse.ps1`（703 行，v1.0）
评审时间：2026-11-15

结论先说：**架构选得对，实现偏脆。** 走 UI Automation 而不注入页面脚本，规避了「改网页」这类争议，也让脚本不依赖油猴；但整个流程建立在一组**硬编码类名 + 像素坐标分组**上，平台一次前端改版就会全线失效，而脚本没有任何降级路径和自检手段。

下面按优先级列。P0 建议发布前改掉，P1 建议进 v1.1，P2 是工程化补齐。

---

## P0 — 影响正确性或安全性

### P0-1 兜底点击可能点到别的程序上

`Invoke-Element`（442–461 行）在 `InvokePattern` 失败时直接走 `[AutoCourseNative]::Click()`，而 `Click`（105–111 行）是 `SetCursorPos` + 全局 `mouse_event`，**不校验当前前台窗口**。轮询期间用户切去别的程序，脚本一兜底点击就会点在那个程序上（可能误点删除、误点提交）。

补丁：点击前校验前台窗口仍属于目标进程。

```powershell
function Invoke-Element {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [IntPtr]$WindowHandle = [IntPtr]::Zero
    )

    try {
        $pattern = $Element.GetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern)
        $pattern.Invoke()
        return $true
    }
    catch {
        # 兜底点击前确认前台窗口还是目标窗口，否则放弃本次点击
        if ($WindowHandle -ne [IntPtr]::Zero) {
            $fg = [AutoCourseNative]::GetForegroundWindow()
            if ($fg -ne $WindowHandle) {
                Write-CourseLog 'Fallback click skipped: target window is not foreground.'
                return $false
            }
        }
        $rect = $Element.Current.BoundingRectangle
        if ($rect.Width -gt 0 -and $rect.Height -gt 0) {
            [AutoCourseNative]::Click(
                [int]($rect.X + ($rect.Width / 2)),
                [int]($rect.Y + ($rect.Height / 2)))
            return $true
        }
        return $false
    }
}
```

调用处同步传句柄：`Move-ToNextVideo` 增加 `-WindowHandle` 参数并透传。

### P0-2 「视频」标签判定用了 `\u89c6\u9891` 转义且锚定为整串

273 行、491 行：

```powershell
$child.Current.Name.Trim() -match '^\u89c6\u9891$'
```

两个问题：

1. `\u89c6\u9891` 在 .NET 正则里确实会解析成「视频」，功能上是对的，但**没人看得出来**这是中文。维护者以为是某种转义占位，改动时容易删错。
2. 真正的问题是锚定 `^...$`：目录里显示成 `视频`、`视频 1`、`视频(2)`、`视频 · 未开始` 的全部漏掉。真实课程里第二章以后的节点经常带序号，于是脚本只播第一章 —— 现象是「跑到某节就停了，日志说 No later video was found」，很容易被误判成「已经看完」。

补丁：

```powershell
$script:VideoLabelPattern = '视频'
$script:NonTitlePattern   = '^(视频|作业|讨论题|考试|测验|课件|PPT)\s*\d*\s*$'

# 判定
if ($child.Current.Name.Trim() -match $script:VideoLabelPattern) { $isVideo = $true }
```

注意把 `isVideo` 改成「标题里含『视频』」而不是「名字完全等于视频」，可显著提高目录识别率。

### P0-3 播完判定可能永远不成立

633 行 `IsComplete` 依赖 `CurrentSeconds >= DurationSeconds - 1`，而 `CurrentSeconds` 来自播放器**显示文本**（只到秒，且末帧常停在 `12:29 / 12:30`）。一旦平台把末秒卡住不推进，`IsComplete` 永远 False，主循环会一直走 686 行的「时间不变」分支，`Resume-Video` 也救不回来 —— **脚本静默卡死，不报错也不前进**。

补丁：加「接近尾部 + 长时间不变」的兜底完成判定。

```powershell
# 主循环内，elseif ($state.CurrentText -eq $lastCurrentText) 分支里
$unchangedPolls++
$nearEnd = (
    $null -ne $state.CurrentSeconds -and
    $null -ne $state.DurationSeconds -and
    $state.DurationSeconds -gt 0 -and
    ($state.DurationSeconds - $state.CurrentSeconds) -le 3
)

if ($nearEnd -and $unchangedPolls -ge 10) {
    Write-CourseLog 'Playback stuck at the end of the video. Treating it as finished.'
    $stuckComplete = $true      # 交给外层按「已完成」处理
}
elseif ($unchangedPolls -ge 5) {
    Write-CourseLog 'Playback time did not change. Checking playback state.'
    if (-not $state.IsPlaying) { $null = Resume-Video -State $state }
    $unchangedPolls = 0
}
```

### P0-4 卡死无升级路径

现在「时间不变 → resume → 清零计数 → 再来一轮」可以无限循环几小时，日志只重复一行 `Playback time did not change.`，用户以为在跑，实际早停了。

补丁：给「同一节课连续判定无进展」加硬上限，超了就切下一节，再超就整体退出并提示。

```powershell
$script:MaxStuckPerLesson = 20      # 同一节最多自愈 20 次
$script:MaxStuckTotal     = 60      # 全程最多 60 次

# 超过 MaxStuckPerLesson：强制 Move-ToNextVideo
# 超过 MaxStuckTotal：Write-CourseLog 'Giving up: playback made no progress.'; break
```

---

## P1 — 稳定性与性能

### P1-1 每轮全树遍历，跨进程往返开销极大

`Get-AllElements`（174–179 行）用 `TreeScope::Descendants` + `TrueCondition`，等于把整个浏览器 UI 树的**全部属性**跨进程拉一遍；而 `Get-VideoState` 一次调用要跑 4~5 遍（286、293、328、431 → `Get-ActiveLessonName` 内又一遍），`Move-ToNextVideo` 再跑 N 遍（每个 `leaf-item` 一次子遍历）。元素数千时单轮耗时可上秒级，这就是「CPU 一直十几二十个点」的原因。

根治用 `CacheRequest` 把属性批量缓存，一次跨进程拿完：

```powershell
function Get-CachedElements {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [System.Windows.Automation.TreeScope]$Scope = [System.Windows.Automation.TreeScope]::Descendants
    )

    $cache = New-Object System.Windows.Automation.CacheRequest
    $cache.TreeFilter = [System.Windows.Automation.Condition]::TrueCondition
    foreach ($p in @(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty,
        [System.Windows.Automation.AutomationElement]::NameProperty,
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.AutomationElement]::BoundingRectangleProperty,
        [System.Windows.Automation.AutomationElement]::IsEnabledProperty,
        [System.Windows.Automation.AutomationElement]::IsOffscreenProperty)) {
        $cache.Add($p)
    }
    $cache.Add([System.Windows.Automation.AutomationElement]::IsInvokePatternAvailableProperty)
    $cache.Activate()

    try {
        return ,$Root.FindAll($Scope, [System.Windows.Automation.Condition]::TrueCondition)
    }
    finally {
        $cache.Dispose()   # 必须 Dispose，否则缓存一直生效影响后续调用
    }
}
```

配套：读属性统一走 `Current`（缓存生效后 `Current` 不再跨进程），并缓存 `Get-ActiveLessonName` 的结果（同一 `ActiveLesson` 字符串不必每轮重算目录标题）。

### P1-2 只有 Write-Host，没有日志文件

`Write-CourseLog`（169–172 行）只输出到控制台。用户关窗口 / 崩溃后什么都查不到，issue 里也没法贴日志。

补丁：

```powershell
$script:LogPath = Join-Path $PSScriptRoot ('logs\autocourse-{0:yyyyMMdd}.log' -f (Get-Date))
New-Item -ItemType Directory -Force (Split-Path $script:LogPath) | Out-Null

function Write-CourseLog {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
    Write-Host $line
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}
```

配 `.gitignore` 忽略 `logs/`（仓库已带）。

### P1-3 互斥量与退出路径不干净

`New-Object Mutex($true, 'Local\YuketangAutoCourse', [ref]$createdNew)`（14–23 行）拿完所有权后没有任何 `finally` 释放；异常退出（`throw` 在 566、574 行）时靠进程结束回收，行为上没问题，但如果将来改成常驻/被别的进程持有就会卡住。同时 `while ($true)` 主循环（604 行）没有 `try/finally`，`Ctrl+C` 时日志不落盘。

补丁：整个主体包进 `try { ... } finally { $courseMutex.ReleaseMutex(); $courseMutex.Dispose() }`，主循环内的 `break` 改为设置 `$stopping = $true`。

### P1-4 浏览器进程名写死 `msedge`

203 行 `$process.ProcessName -ne 'msedge'`。用 Chrome、Edge Beta、或老师要求用某专用客户端的同学直接不能用。

补丁：加参数 `-ProcessName @('msedge','chrome')` 默认两者都认，`Find-CourseWindow` 里用 `-contains` 判断。

---

## P2 — 工程化

| 项 | 位置 | 处理 |
| --- | --- | --- |
| 死代码 `Test-HasPlayer` | 181–191 | 与 `Find-CourseWindow` 内联逻辑重复，删掉 |
| 无版本号 | 全文 | 加 `$script:Version = '1.1.0'` 并在启动日志里打印，issue 里好定位 |
| 无「最多播几个」上限 | 主循环 | 加 `-MaxVideos`，防止挂一晚上把整学期播完 |
| 无异常兜底日志 | 全文 `catch { continue }` 多处 | 至少 `Write-CourseLog` 一行，别静默吞 |
| 中文注释缺失 | 全文英文日志 | 面向中文用户，日志改中文或双语 |
| `-Once` 输出不含类名清单 | 577–586 | 加一段「识别到的播放器类名 / 目录节点数」，改版排查神器 |

---

## 架构建议（v2 方向）

现在这套的脆弱点不是代码质量，是**信息源**：类名 + 像素坐标。两个更稳的路子：

### 方案 A：CDP（推荐）

Edge / Chrome 都能用 `--remote-debugging-port=9222` 启动，然后脚本用 `ClientWebSocket` 连上去执行 JS：

```javascript
// 读真实状态，不依赖任何类名
const v = document.querySelector('video');
({ t: v.currentTime, d: v.duration, paused: v.paused, rate: v.playbackRate })
```

好处：

- 拿到的是**精确到毫秒的真实时间**，`IsComplete` 不再靠猜
- 可以后台跑，不抢鼠标、不需要窗口前台、可以最小化
- 能读 DOM，于是**弹题检测**变得可行（`document.querySelector('.problem-*')` 之类）
- 能顺手做倍速（`v.playbackRate = 1.5`），但要注意：改倍速会让「正常播放」的边界变模糊，是否提供由你决定
- 一次拿完所有状态，单轮开销从「秒级」降到「毫秒级」

代价：需要以带调试端口的方式重启浏览器，或写一个拉起浏览器的启动器。

### 方案 B：PowerShell 版油猴（直接注入 JS）

保持零依赖，但把 DOM 操作放到页面里：用 `ExecuteScript` 之类的手段注入一小段 JS，通过 `document.title` 或剪贴板把状态回传给 PowerShell。比 UIA 稳，比 CDP 门槛低，但注入手段本身又回到「改网页」的争议上。

按你现在的定位（不改网页、不碰倍速），**方案 A 是纯收益**：它同样不改页面，只是换了一个更准的眼睛。

---

## 发布前 checklist

- [x] README 说清「做什么 / 不做什么」
- [x] LICENSE（MIT）+ 免责声明
- [x] `.gitignore`（logs、STOP 标记文件、`*.zip`）
- [x] CHANGELOG + 版本号
- [x] Issue 模板（bug 报告要求贴日志）
- [x] Release 工作流（打 tag 自动出 zip）
- [ ] P0-1 ~ P0-4 补丁合入
- [ ] `-Once` 增加类名自检输出（改版后用户能自助定位）
