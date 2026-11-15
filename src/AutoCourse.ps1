[CmdletBinding()]
param(
    [int]$PollSeconds = 2,
    [switch]$Once,
    [switch]$NextNow,
    [string[]]$ProcessName = @('msedge', 'chrome'),
    [int]$MaxVideos = 0,
    [int]$MaxStuckPerLesson = 20,
    [int]$MaxStuckTotal = 60
)

# ============================================================================
# 雨课堂自动连播 v1.1.0
# 只做三件事：暂停就续播 / 播完切下一节视频 / 卡住就自愈。
# 不碰倍速、不拖进度、不改页面、不处理作业与测试。
# ============================================================================

$ErrorActionPreference = 'Stop'

$script:Version         = '1.1.0'
$script:LogFile         = Join-Path $PSScriptRoot ('logs\autocourse-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$script:StopFile        = Join-Path $PSScriptRoot 'STOP_AUTOCOURSE'
$script:ExitCode        = 0

# 平台结构特征，改版后只需动这里
$script:VideoClassPattern = '^xt_video_player(?:\s|_)'
$script:LeafClassPattern  = '^leaf-item(?:\s|$)'
$script:VideoLabelPattern = '视频'
$script:NonTitlePattern   = '^(视频|作业|讨论题|考试|测验|课件|PPT|直播|回放)\s*[0-9]*\s*$'

function Write-CourseLog {
    param([string]$Message)

    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
    Write-Host $line

    try {
        $dir = Split-Path -Parent $script:LogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
    catch {
        # 日志落盘失败不影响主流程
    }
}

# ---------------------------------------------------------------------------
# 单实例保护
# ---------------------------------------------------------------------------

$createdNew = $false
$courseMutex = New-Object System.Threading.Mutex(
    $true,
    'Local\YuketangAutoCourse',
    [ref]$createdNew)

if (-not $createdNew) {
    Write-Host '已有自动连播实例在运行，本次不重复启动。'
    exit 1
}

# ---------------------------------------------------------------------------
# Win32 互操作
# ---------------------------------------------------------------------------

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('AutoCourseNative' -as [type])) {
    Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class AutoCourseNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public struct Point
    {
        public int X;
        public int Y;
    }

    public struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr SetFocus(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr handle, out Rect rect);

    [DllImport("user32.dll")]
    public static extern bool mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(Point point);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr handle, uint flags);

    /// <summary>点击指定屏幕坐标。0x0002 按下，0x0004 抬起。</summary>
    public static void Click(int x, int y)
    {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }

    /// <summary>返回坐标所在的最顶层窗口，用于点击前确认不会点到别处。</summary>
    public static IntPtr RootWindowAt(int x, int y)
    {
        var point = new Point { X = x, Y = y };
        var handle = WindowFromPoint(point);
        if (handle == IntPtr.Zero)
        {
            return IntPtr.Zero;
        }
        // GA_ROOT = 2
        return GetAncestor(handle, 2);
    }

    public static List<IntPtr> GetVisibleWindows()
    {
        var windows = new List<IntPtr>();
        EnumWindows((handle, _) =>
        {
            if (IsWindowVisible(handle))
            {
                windows.Add(handle);
            }
            return true;
        }, IntPtr.Zero);
        return windows;
    }

    public static string GetTitle(IntPtr handle)
    {
        var text = new StringBuilder(512);
        GetWindowText(handle, text, text.Capacity);
        return text.ToString();
    }

    public static uint GetProcessId(IntPtr handle)
    {
        uint processId;
        GetWindowThreadProcessId(handle, out processId);
        return processId;
    }

    public static void ForceForeground(IntPtr handle)
    {
        ShowWindow(handle, 3);
        IntPtr foreground = GetForegroundWindow();
        uint currentThread = GetCurrentThreadId();
        uint foregroundProcessId;
        uint foregroundThread = GetWindowThreadProcessId(foreground, out foregroundProcessId);

        if (foregroundThread != 0)
        {
            AttachThreadInput(currentThread, foregroundThread, true);
        }

        BringWindowToTop(handle);
        SetForegroundWindow(handle);
        SetFocus(handle);

        if (foregroundThread != 0)
        {
            AttachThreadInput(currentThread, foregroundThread, false);
        }
    }
}
'@
}

# ---------------------------------------------------------------------------
# UI Automation 读取（带属性缓存，避免每轮多次跨进程往返）
# ---------------------------------------------------------------------------

$script:CachedProperties = @(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty,
    [System.Windows.Automation.AutomationElement]::NameProperty,
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.AutomationElement]::BoundingRectangleProperty,
    [System.Windows.Automation.AutomationElement]::IsEnabledProperty,
    [System.Windows.Automation.AutomationElement]::IsOffscreenProperty
)

function Get-CachedElements {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [System.Windows.Automation.TreeScope]$Scope = [System.Windows.Automation.TreeScope]::Descendants
    )

    $cache = New-Object System.Windows.Automation.CacheRequest
    $cache.TreeFilter = [System.Windows.Automation.Condition]::TrueCondition

    foreach ($property in $script:CachedProperties) {
        $cache.Add($property)
    }

    $cache.Activate()
    try {
        return ,$Root.FindAll($Scope, [System.Windows.Automation.Condition]::TrueCondition)
    }
    finally {
        # 必须释放，否则缓存一直生效，后续读未缓存属性会抛异常
        $cache.Dispose()
    }
}

function Get-ElementClass {
    param([System.Windows.Automation.AutomationElement]$Element)

    try {
        return [string]$Element.Current.ClassName
    }
    catch {
        return ''
    }
}

function Test-HasPlayer {
    param([System.Windows.Automation.AutomationElement]$Root)

    $all = Get-CachedElements -Root $Root
    foreach ($element in $all) {
        if ((Get-ElementClass $element) -match $script:VideoClassPattern) {
            return $true
        }
    }
    return $false
}

function Find-CourseWindow {
    foreach ($handle in [AutoCourseNative]::GetVisibleWindows()) {
        $processId = [AutoCourseNative]::GetProcessId($handle)
        if ($processId -eq 0) {
            continue
        }

        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if (-not $process -or $ProcessName -notcontains $process.ProcessName) {
            continue
        }

        $title = [AutoCourseNative]::GetTitle($handle)
        if ([string]::IsNullOrWhiteSpace($title)) {
            continue
        }

        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
            if (-not $root) {
                continue
            }

            if (Test-HasPlayer -Root $root) {
                return [pscustomobject]@{
                    Handle = $handle
                    Root   = $root
                    Title  = $title
                }
            }
        }
        catch {
            continue
        }
    }

    return $null
}

function Convert-TimeTextToSeconds {
    param([string]$Text)

    if ($Text -notmatch '^\d{1,3}:\d{2}(:\d{2})?$') {
        return $null
    }

    $parts = $Text.Split(':') | ForEach-Object { [double]$_ }
    if ($parts.Count -eq 2) {
        return ($parts[0] * 60) + $parts[1]
    }
    if ($parts.Count -eq 3) {
        return ($parts[0] * 3600) + ($parts[1] * 60) + $parts[2]
    }
    return $null
}

function Test-RectContains {
    param($Outer, $Inner)

    $cx = $Inner.X + ($Inner.Width / 2)
    $cy = $Inner.Y + ($Inner.Height / 2)

    return (
        $cx -ge $Outer.X -and
        $cx -le $Outer.Right -and
        $cy -ge $Outer.Y -and
        $cy -le $Outer.Bottom
    )
}

function Get-LeafLessons {
    param($AllElements)

    $leaves = @()
    $texts = @()

    foreach ($element in $AllElements) {
        $className = Get-ElementClass $element
        if ($className -match $script:LeafClassPattern) {
            $leaves += $element
            continue
        }

        try {
            if ($element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text) {
                if ($element.Current.Name) {
                    $texts += $element
                }
            }
        }
        catch {
            continue
        }
    }

    $lessons = @()

    foreach ($leaf in $leaves) {
        try {
            $leafRect = $leaf.Current.BoundingRectangle
            $className = Get-ElementClass $leaf
        }
        catch {
            continue
        }

        $names = @()
        $isVideo = $false

        if ($leafRect.Width -gt 0 -and $leafRect.Height -gt 0) {
            foreach ($text in $texts) {
                try {
                    $textRect = $text.Current.BoundingRectangle
                }
                catch {
                    continue
                }

                if (-not (Test-RectContains -Outer $leafRect -Inner $textRect)) {
                    continue
                }

                $name = $text.Current.Name.Trim()
                if (-not $name) {
                    continue
                }

                $names += $name
                if ($name -match $script:VideoLabelPattern) {
                    $isVideo = $true
                }
            }
        }

        $title = (
            $names |
                Where-Object { $_ -notmatch $script:NonTitlePattern } |
                Select-Object -Unique
        ) -join ' '

        $lessons += [pscustomobject]@{
            Element  = $leaf
            Y        = $leafRect.Y
            IsActive = ($className -match '^leaf-item is-active')
            IsVideo  = $isVideo
            Title    = $title
        }
    }

    return ,@($lessons | Sort-Object -Property Y)
}

function Get-ActiveLessonName {
    param($Lessons)

    foreach ($lesson in $Lessons) {
        if ($lesson.IsActive) {
            if ($lesson.Title) {
                return $lesson.Title
            }
            return '(未命名节点)'
        }
    }

    return $null
}

function Get-VideoState {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [switch]$SkipReveal,
        [IntPtr]$WindowHandle = [IntPtr]::Zero
    )

    $all = Get-CachedElements -Root $Root
    if ($all.Count -eq 0) {
        return $null
    }

    $player = $null
    $playButton = $null
    $playerClassName = $null
    $largestArea = -1

    foreach ($element in $all) {
        $className = Get-ElementClass $element
        if ($className -notmatch $script:VideoClassPattern) {
            continue
        }

        if ($className -match '^xt_video_player_play_btn(?:\s|$)') {
            $playButton = $element
        }

        # 容器节点：排除已知的控件子节点，取面积最大的
        if ($className -match
            '^xt_video_player_(?:play_btn|progress|seek|fullscreen|common)') {
            continue
        }

        try {
            $rect = $element.Current.BoundingRectangle
        }
        catch {
            continue
        }

        $area = $rect.Width * $rect.Height
        if ($area -gt $largestArea) {
            $largestArea = $area
            $player = $element
            $playerClassName = $className
        }
    }

    if (-not $player) {
        return $null
    }

    $playerRect = $player.Current.BoundingRectangle
    $timeElements = @()

    foreach ($element in $all) {
        try {
            if ($element.Current.ControlType -ne [System.Windows.Automation.ControlType]::Text) {
                continue
            }

            $name = $element.Current.Name
            if ($name -notmatch '^\d{1,3}:\d{2}(:\d{2})?$') {
                continue
            }

            $rect = $element.Current.BoundingRectangle
        }
        catch {
            continue
        }

        $insideHorizontalBand =
            $rect.X -ge ($playerRect.X - 30) -and
            $rect.X -le ($playerRect.Right + 30)
        $insideBottomBand =
            $rect.Y -ge ($playerRect.Y + 40) -and
            $rect.Y -le ($playerRect.Y + $playerRect.Height + 150)

        if ($insideHorizontalBand -and $insideBottomBand) {
            $timeElements += [pscustomobject]@{
                Text = $name
                X    = $rect.X
                Y    = [int]$rect.Y
            }
        }
    }

    $timeRow = $timeElements |
        Group-Object -Property Y |
        Where-Object { $_.Count -ge 2 } |
        Sort-Object { [int]$_.Name } -Descending |
        Select-Object -First 1

    if ($timeRow) {
        $timeElements = @($timeRow.Group | Sort-Object -Property X)
    }
    else {
        $timeElements = @()
    }

    # 控制条默认隐藏，读不到时间就把鼠标移过去让它浮出来，读完还原
    if ($timeElements.Count -lt 2 -and -not $SkipReveal) {
        $cursor = [AutoCourseNative+Point]::new()
        $hasCursor = [AutoCourseNative]::GetCursorPos([ref]$cursor)
        $left = $playerRect.X + 20
        $right = $playerRect.Right - 20
        $bottom = $playerRect.Bottom - 30

        if ($WindowHandle -ne [IntPtr]::Zero) {
            $windowRect = [AutoCourseNative+Rect]::new()
            if ([AutoCourseNative]::GetWindowRect($WindowHandle, [ref]$windowRect)) {
                $left = [Math]::Max($left, $windowRect.Left + 20)
                $right = [Math]::Min($right, $windowRect.Right - 20)
                $bottom = [Math]::Min($bottom, $windowRect.Bottom - 20)
            }
        }

        if ($right -le $left) {
            return $null
        }

        $hoverX = [int](($left + $right) / 2)
        $hoverY = [int]($bottom - 60)

        try {
            if ($WindowHandle -ne [IntPtr]::Zero) {
                [AutoCourseNative]::ForceForeground($WindowHandle)
                Start-Sleep -Milliseconds 150
            }
            [AutoCourseNative]::SetCursorPos($hoverX, $hoverY) | Out-Null
            Start-Sleep -Milliseconds 900
            return Get-VideoState -Root $Root -SkipReveal -WindowHandle $WindowHandle
        }
        finally {
            if ($hasCursor) {
                [AutoCourseNative]::SetCursorPos($cursor.X, $cursor.Y) | Out-Null
            }
        }
    }

    $currentSeconds = $null
    $durationSeconds = $null

    if ($timeElements.Count -ge 2) {
        $currentSeconds = Convert-TimeTextToSeconds $timeElements[0].Text
        $durationSeconds = Convert-TimeTextToSeconds $timeElements[-1].Text
    }

    $isPlaying = $false
    if ($playButton) {
        $isPlaying = (Get-ElementClass $playButton) -match 'xt_video_player_play_btn_pause'
    }

    $isComplete = (
        $null -ne $currentSeconds -and
        $null -ne $durationSeconds -and
        $durationSeconds -gt 0 -and
        $currentSeconds -ge ($durationSeconds - 1)
    )

    $lessons = Get-LeafLessons -AllElements $all

    return [pscustomobject]@{
        Player          = $player
        PlayButton      = $playButton
        PlayerClass     = $playerClassName
        LessonCount     = $lessons.Count
        VideoCount      = @($lessons | Where-Object { $_.IsVideo }).Count
        ActiveLesson    = Get-ActiveLessonName -Lessons $lessons
        CurrentText     = if ($timeElements.Count -ge 2) { $timeElements[0].Text } else { $null }
        DurationText    = if ($timeElements.Count -ge 2) { $timeElements[-1].Text } else { $null }
        CurrentSeconds  = $currentSeconds
        DurationSeconds = $durationSeconds
        HasTime         = ($timeElements.Count -ge 2)
        IsPlaying       = $isPlaying
        IsComplete      = $isComplete
    }
}

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
        # InvokePattern 不可用时才退回鼠标点击，且必须确认点击会落在目标窗口上
    }

    try {
        $rect = $Element.Current.BoundingRectangle
    }
    catch {
        return $false
    }

    if ($rect.Width -le 0 -or $rect.Height -le 0) {
        return $false
    }

    $x = [int]($rect.X + ($rect.Width / 2))
    $y = [int]($rect.Y + ($rect.Height / 2))

    if ($WindowHandle -ne [IntPtr]::Zero) {
        $foreground = [AutoCourseNative]::GetForegroundWindow()
        if ($foreground -ne $WindowHandle) {
            Write-CourseLog '目标窗口不在前台，已跳过兜底点击（避免误点到其他程序）。'
            return $false
        }

        $rootAtPoint = [AutoCourseNative]::RootWindowAt($x, $y)
        if ($rootAtPoint -ne [IntPtr]::Zero -and $rootAtPoint -ne $WindowHandle) {
            Write-CourseLog '目标坐标被其他窗口遮挡，已跳过兜底点击。'
            return $false
        }
    }

    [AutoCourseNative]::Click($x, $y)
    return $true
}

function Resume-Video {
    param(
        $State,
        [IntPtr]$WindowHandle = [IntPtr]::Zero
    )

    if (-not $State.PlayButton) {
        return $false
    }

    return Invoke-Element -Element $State.PlayButton -WindowHandle $WindowHandle
}

function Move-ToNextVideo {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [IntPtr]$WindowHandle = [IntPtr]::Zero
    )

    $all = Get-CachedElements -Root $Root
    $lessons = Get-LeafLessons -AllElements $all

    $activeIndex = -1
    for ($i = 0; $i -lt $lessons.Count; $i++) {
        if ($lessons[$i].IsActive) {
            $activeIndex = $i
            break
        }
    }

    if ($activeIndex -lt 0) {
        Write-CourseLog '未找到当前高亮的课程节点，请手动点开一个视频后重试。'
        return $false
    }

    for ($i = $activeIndex + 1; $i -lt $lessons.Count; $i++) {
        $next = $lessons[$i]
        if (-not $next.IsVideo) {
            continue
        }

        Write-CourseLog ('打开下一个视频节点：{0}' -f $next.Title)

        try {
            $scrollPattern = $next.Element.GetCurrentPattern(
                [System.Windows.Automation.ScrollItemPattern]::Pattern)
            $scrollPattern.ScrollIntoView()
            Start-Sleep -Milliseconds 300
        }
        catch {
            Write-CourseLog '该节点无法滚动到可视区域，跳过。'
            continue
        }

        if (Invoke-Element -Element $next.Element -WindowHandle $WindowHandle) {
            Start-Sleep -Seconds 2
            return $true
        }
    }

    Write-CourseLog '后面已经没有可播放的视频节点了，自动连播结束。'
    return $false
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

try {
    Write-CourseLog ('雨课堂自动连播 v{0} 启动' -f $script:Version)
    Write-CourseLog ('日志文件：{0}' -f $script:LogFile)

    if ($PollSeconds -lt 1) {
        Write-CourseLog 'PollSeconds 必须大于等于 1。'
        exit 1
    }

    if (Test-Path -LiteralPath $script:StopFile) {
        Remove-Item -LiteralPath $script:StopFile -Force
    }

    Write-CourseLog ('正在查找浏览器窗口（进程：{0}）...' -f ($ProcessName -join ', '))
    $courseWindow = Find-CourseWindow

    if (-not $courseWindow) {
        Write-CourseLog '未找到包含播放器的浏览器窗口。请先用 Edge 打开雨课堂视频页并等播放器加载出来。'
        exit 1
    }

    Write-CourseLog ('已锁定窗口：{0}' -f $courseWindow.Title)

    $edgeHandle = $courseWindow.Handle
    [AutoCourseNative]::ForceForeground($edgeHandle)

    $state = Get-VideoState -Root $courseWindow.Root -WindowHandle $edgeHandle
    if (-not $state) {
        Write-CourseLog '窗口中未识别到播放器，可能页面还没加载完。'
        exit 1
    }

    if ($Once) {
        Write-CourseLog '自检模式，不操作页面。'
        [pscustomobject]@{
            Version      = $script:Version
            WindowTitle  = $courseWindow.Title
            PlayerClass  = $state.PlayerClass
            LessonCount  = $state.LessonCount
            VideoCount   = $state.VideoCount
            ActiveLesson = $state.ActiveLesson
            CurrentTime  = $state.CurrentText
            Duration     = $state.DurationText
            IsPlaying    = $state.IsPlaying
            IsComplete   = $state.IsComplete
        } | Format-List

        # 平台改版时，这两行是唯一的排错线索
        Write-CourseLog (
            '播放器类名 {0} / 目录节点 {1} 个（其中视频 {2} 个）' -f
            $state.PlayerClass, $state.LessonCount, $state.VideoCount)
        exit 0
    }

    if ($NextNow) {
        $moved = Move-ToNextVideo -Root $courseWindow.Root -WindowHandle $edgeHandle
        if (-not $moved) {
            $script:ExitCode = 1
        }
        exit 0
    }

    Write-CourseLog '自动连播已启动，保持该标签页打开；停止请双击 停止自动连播.cmd 或按 Ctrl+C。'
    Write-CourseLog '不修改倍速、不静音、不拖动进度、不答题。'

    $lastLesson      = $state.ActiveLesson
    $lastCurrentText = $state.CurrentText
    $unchangedPolls  = 0
    $stuckPerLesson  = 0
    $stuckTotal      = 0
    $completedCount  = 0

    while ($true) {
        if (Test-Path -LiteralPath $script:StopFile) {
            Remove-Item -LiteralPath $script:StopFile -Force
            Write-CourseLog '收到停止请求，退出。'
            break
        }

        Start-Sleep -Seconds $PollSeconds

        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($edgeHandle)
            if (-not $root) {
                Write-CourseLog '窗口句柄失效，重新查找窗口。'
                $courseWindow = Find-CourseWindow
                if (-not $courseWindow) {
                    Write-CourseLog '找不到目标窗口了，退出。'
                    $script:ExitCode = 1
                    break
                }
                $edgeHandle = $courseWindow.Handle
                $root = $courseWindow.Root
            }

            $state = Get-VideoState -Root $root -WindowHandle $edgeHandle
        }
        catch {
            Write-CourseLog '页面暂时不可读，稍后重试。'
            continue
        }

        if (-not $state) {
            Write-CourseLog '还没识别到播放器，等待页面加载。'
            continue
        }

        if ($state.ActiveLesson -and $state.ActiveLesson -ne $lastLesson) {
            Write-CourseLog ('进入新节点：{0}' -f $state.ActiveLesson)
            $lastLesson     = $state.ActiveLesson
            $unchangedPolls = 0
            $stuckPerLesson = 0
        }

        $nearEnd = (
            $null -ne $state.CurrentSeconds -and
            $null -ne $state.DurationSeconds -and
            $state.DurationSeconds -gt 0 -and
            ($state.DurationSeconds - $state.CurrentSeconds) -le 3
        )

        $finished = [bool]$state.IsComplete

        # 播放器停在末帧不再推进时，长时间不变即按看完处理
        if (-not $finished -and $nearEnd -and $unchangedPolls -ge 8) {
            Write-CourseLog '播放时间停在片尾不再推进，按已看完处理。'
            $finished = $true
        }

        if ($finished) {
            $completedCount++
            Write-CourseLog ('本节播放结束：{0} / {1}' -f $state.CurrentText, $state.DurationText)

            if ($MaxVideos -gt 0 -and $completedCount -ge $MaxVideos) {
                Write-CourseLog ('已达到设定的最大播放数量 {0}，退出。' -f $MaxVideos)
                break
            }

            $completedLesson = $state.ActiveLesson
            Write-CourseLog '等待平台保存进度...'
            Start-Sleep -Seconds 3

            $root = [System.Windows.Automation.AutomationElement]::FromHandle($edgeHandle)
            $stateAfterWait = $null
            if ($root) {
                $stateAfterWait = Get-VideoState -Root $root -WindowHandle $edgeHandle
            }

            # 平台自己跳到了下一节
            if ($stateAfterWait -and
                -not $stateAfterWait.IsComplete -and
                $stateAfterWait.HasTime -and
                $stateAfterWait.ActiveLesson -and
                $stateAfterWait.ActiveLesson -ne $completedLesson) {
                Write-CourseLog ('平台已自动切到：{0}' -f $stateAfterWait.ActiveLesson)
                $lastLesson      = $stateAfterWait.ActiveLesson
                $lastCurrentText = $stateAfterWait.CurrentText
                $unchangedPolls  = 0
                $stuckPerLesson  = 0
                continue
            }

            if (-not $root) {
                continue
            }

            $moved = Move-ToNextVideo -Root $root -WindowHandle $edgeHandle
            if (-not $moved) {
                break
            }

            Start-Sleep -Seconds 2
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($edgeHandle)
            if ($root) {
                $state = Get-VideoState -Root $root -WindowHandle $edgeHandle
                if ($state -and $state.ActiveLesson) {
                    Write-CourseLog ('进入新节点：{0}' -f $state.ActiveLesson)
                    $lastLesson = $state.ActiveLesson
                }
            }

            $unchangedPolls = 0
            $stuckPerLesson = 0
            continue
        }

        if (-not $state.IsPlaying) {
            if (Resume-Video -State $state -WindowHandle $edgeHandle) {
                Write-CourseLog (
                    '视频处于暂停，已点播放：{0} / {1}' -f
                    $state.CurrentText, $state.DurationText)
            }
            else {
                Write-CourseLog '视频处于暂停，但播放按钮不可点（可能有弹窗或题目遮挡）。'
                $stuckTotal++
                if ($stuckTotal -ge $MaxStuckTotal) {
                    Write-CourseLog '多次无法恢复播放，退出。'
                    $script:ExitCode = 1
                    break
                }
            }
            $unchangedPolls = 0
        }
        elseif ($state.CurrentText -and $state.CurrentText -eq $lastCurrentText) {
            $unchangedPolls++
            if ($unchangedPolls -ge 5) {
                Write-CourseLog ('播放时间连续 {0} 轮无变化：{1}' -f $unchangedPolls, $state.CurrentText)
                $stuckPerLesson++
                $stuckTotal++

                if ($stuckPerLesson -ge $MaxStuckPerLesson) {
                    Write-CourseLog '本节反复卡住，尝试跳到下一节。'
                    $root = [System.Windows.Automation.AutomationElement]::FromHandle($edgeHandle)
                    if ($root -and (Move-ToNextVideo -Root $root -WindowHandle $edgeHandle)) {
                        Start-Sleep -Seconds 2
                        $unchangedPolls = 0
                        $stuckPerLesson = 0
                        continue
                    }
                    Write-CourseLog '无法跳到下一节，退出。'
                    $script:ExitCode = 1
                    break
                }

                if ($stuckTotal -ge $MaxStuckTotal) {
                    Write-CourseLog '全程卡住次数超过上限，退出。'
                    $script:ExitCode = 1
                    break
                }
            }
        }
        else {
            $unchangedPolls = 0
            $stuckPerLesson = 0
        }

        $lastCurrentText = $state.CurrentText
    }

    Write-CourseLog ('自动连播结束，本次共播完 {0} 个视频。' -f $completedCount)
}
finally {
    if ($courseMutex) {
        try {
            $courseMutex.ReleaseMutex()
        }
        catch {
        }
        $courseMutex.Dispose()
    }

    if (Test-Path -LiteralPath $script:StopFile) {
        Remove-Item -LiteralPath $script:StopFile -Force -ErrorAction SilentlyContinue
    }
}

exit $script:ExitCode
