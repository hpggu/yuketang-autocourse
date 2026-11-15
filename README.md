# 雨课堂自动连播（Yuketang AutoCourse）

> 用 Windows UI Automation 驱动浏览器，把雨课堂「学习空间」里的视频一个个连着放完：自动点播放、播完自动进下一节。
> 不注入页面脚本、不改倍速、不碰作业与测试。

<p align="left">
  <img alt="version" src="https://img.shields.io/badge/version-1.1.1-blue">
  <img alt="platform" src="https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4">
  <img alt="runtime" src="https://img.shields.io/badge/runtime-PowerShell%205.1%2B-5391FE">
  <img alt="browser" src="https://img.shields.io/badge/browser-Edge%20%2F%20Chrome-1B9AAA">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-green">
</p>

---

## 它做什么

| 能力 | 说明 |
| --- | --- |
| 自动播放 | 检测到播放器处于暂停状态就点播放 |
| 卡住自愈 | 播放时间连续多轮不变时，重新检查播放状态并续播；本节反复卡住会自动跳到下一节 |
| 自动下一节 | 当前视频播完后，在左侧目录里找**后面第一个视频节点**并点开，自动跳过作业 / 讨论题 |
| 进度兜底 | 播完先等 3 秒，若平台自己跳了下一节就跟随，避免重复点击 |
| 片尾兜底 | 播放器停在最后一帧不推进时，超过若干轮按「已看完」处理，不会原地卡死 |
| 可随时停 | 双击 `停止自动连播.cmd`，或在窗口里按 `Ctrl+C` |
| 单实例保护 | 用命名互斥量保证只跑一个实例，避免双击两次互相点 |
| 日志留痕 | 每次运行都写 `logs\autocourse-*.log`，出问题直接看日志 |

## 它不做什么

- 不改播放倍速、不静音、不拖动进度条、不伪造播放进度上报
- 不处理视频中途弹出的题目、不答题、不签到
- 不处理作业、讨论题、考试
- 不绕过任何平台检测，也不保证进度被平台记为「已完成」

> 这一点很重要：本项目只负责「把视频按正常速度连续播放下去」，其余事情一概不管。

---

## 快速开始

### 环境

- Windows 10 / 11
- PowerShell 5.1（系统自带即可，不需要装 PowerShell 7）
- Microsoft Edge（默认）或 Chrome

### 步骤

1. 用浏览器打开雨课堂「学习空间」，**登录**，进入任意一门课。
2. 点开**任意一个视频**，确认播放器已经加载出来（能看到进度条和时间）。
3. 保持这个标签页打开，可以切到别的窗口，但**不要最小化浏览器**。
4. 双击 `src/启动自动连播.cmd`。
5. 窗口里出现「自动连播已启动」就说明接管成功了。
6. 要停：双击 `src/停止自动连播.cmd`，或者在那个黑窗口里按 `Ctrl+C`。

### 命令行参数

```powershell
# 默认：每 2 秒检查一次，一直跑到没有下一个视频
powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1

# 只报告一次当前状态，不动页面（排查问题先用这个）
powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1 -Once

# 立刻切到下一节视频（不动播放状态）
powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1 -NextNow

# 拉长轮询间隔，降低 CPU 占用
powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1 -PollSeconds 5

# 只放完 3 个视频就停
powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1 -MaxVideos 3

# 用 Chrome 而不是 Edge
powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1 -ProcessName chrome
```

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-PollSeconds` | `2` | 轮询间隔（秒），最小 1 |
| `-Once` | — | 只打印一次状态就退出，不操作页面 |
| `-NextNow` | — | 立刻切到下一个视频节点 |
| `-ProcessName` | `msedge, chrome` | 目标浏览器进程名，可传多个 |
| `-MaxVideos` | `0` | 本次最多播放几节，`0` 表示不限制 |
| `-MaxStuckPerLesson` | `20` | 同一节卡住多少次后尝试跳到下一节 |
| `-MaxStuckTotal` | `60` | 全程卡住多少次后退出 |

`-Once` 输出示例：

```
Version      : 1.1.1
WindowTitle  : 学习空间 - 雨课堂
PlayerClass  : xt_video_player
LessonCount  : 12
VideoCount   : 8
ActiveLesson : 第 3 章 数组与对象 视频
CurrentTime  : 04:12
Duration     : 12:30
IsPlaying    : True
IsComplete   : False
```

`PlayerClass` / `LessonCount` / `VideoCount` 是专门留给排错用的：平台前端一改版，先看这三项是不是空 / 0。

---

## 工作原理

一句话：**不碰网页，只像人一样看屏幕、点按钮。**

1. 用 `EnumWindows` 枚举所有可见窗口，按进程名（默认 `msedge`、`chrome`）过滤，再用 UI Automation 在窗口的元素树里找类名匹配 `xt_video_player` 的节点，锁定播放器所在窗口。找到第一个就停，不做无谓遍历。
2. 用 `CacheRequest` 一次性缓存 ClassName / Name / ControlType / BoundingRectangle 等属性，把整棵树拉回内存再算，一轮只跨进程遍历一次。
3. 从无障碍树里读播放器区域的 `mm:ss` 文本，按 Y 坐标聚成一行，取最左为当前时间、最右为总时长。
4. 看播放按钮的类名后缀判断是否在播（`..._play_btn_pause` 表示正在播）。
5. 当前时间 ≥ 总时长 − 1 秒即认为播完；若停在片尾不推进，时间连续 8 轮不变也按播完处理。然后定位左侧目录 `leaf-item` 节点，从「当前高亮节点」往后找第一个带「视频」标签的节点点开。
6. 全程优先调用 UI Automation 的 `InvokePattern`；只有在不可用时才退回 `SetCursorPos + mouse_event` 兜底点击，而兜底前会校验**当前前台窗口是不是目标窗口**、**点击坐标有没有被别的窗口挡住**，任一不满足就跳过。

因为走的是浏览器无障碍树而不是 DOM 注入，所以：

- 不需要装油猴、不需要改网页、不需要证书
- 平台前端框架换版本时，只要类名还在就还能用
- 但类名一变就失效 —— 这是它最大的脆弱点，见 [docs/REVIEW.md](docs/REVIEW.md)

### 已知限制

- **只认 Chromium 系桌面浏览器**：Firefox、内嵌 WebView 的客户端都不识别。
- **控制条是隐藏的**：脚本会把鼠标移到播放器底部 0.9 秒让控制条浮出来读时间，然后**把鼠标位置还原**。这几百毫秒内如果你正在拖动鼠标，可能会被抢一下。
- **浏览器不能最小化**：最小化后无障碍树不完整，读不到时间。
- **窗口缩放 / 系统 DPI 变化**：时间文本按像素坐标分组，缩放比例变化后可能读不到，走 `-Once` 能看到 `CurrentTime` 为空。
- **多显示器 + 多窗口**：锁定第一个含播放器的窗口，不保证是你想要的那个。请只留一个雨课堂窗口。
- **弹题遮挡必然卡住**：视频中途弹出随堂测验时，播放器被浮层盖住，脚本点不到播放按钮，只能累计计数后退出。这类课程需要有人守着处理弹题。

---

## 常见问题

**启动就报「未找到包含播放器的浏览器窗口」**
没找到含播放器的浏览器窗口。确认：视频页已打开、播放器已加载、浏览器没有被最小化、用的是 Edge 或 Chrome（其他浏览器用 `-ProcessName` 指定进程名）。

**报「窗口中未识别到播放器，可能页面还没加载完」**
窗口找到了但播放器还没渲染完。等 3–5 秒重跑，或先手动点一下播放。

**能跑但一直刷「还没识别到播放器，等待页面加载」**
页面在刷新或跳转。正常会自己恢复；超过 1 分钟还这样，用 `-Once` 看是不是类名变了。

**读不到时间（`CurrentTime` 是空的）**
浏览器缩放不是 100%，或播放器被别的浮层挡住。把缩放调回 100% 再试。

**日志里反复出现「视频处于暂停，但播放按钮不可点」**
多半是弹题、弹窗或未关闭的提示浮层盖在播放器上。手动处理掉遮挡后脚本会自动继续。

**担心点到别的程序上**
1.1.0 起兜底点击前会校验前台窗口与遮挡，通不过就跳过并写日志。即便如此，跑的时候也建议别在别的窗口做需要精确点击的操作。

**想看这次到底发生了什么**
打开 `logs\autocourse-<时间戳>.log`，每次运行一个文件。

---

## 目录结构

```
yuketang-autocourse/
├── src/
│   ├── AutoCourse.ps1        # 主脚本
│   ├── 启动自动连播.cmd      # 双击启动
│   ├── 停止自动连播.cmd      # 双击停止
│   └── logs/                 # 运行日志（自动生成，不进版本库）
├── docs/
│   ├── USAGE.md              # 详细使用说明
│   └── REVIEW.md             # 已知问题与改进路线（含逐条补丁）
├── .github/
│   ├── ISSUE_TEMPLATE/
│   └── workflows/
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

## 免责声明

本项目是**浏览器无障碍接口的个人学习辅助工具**，只做「播放 / 切下一节」两件事，不修改平台数据、不伪造学习记录、不绕过任何考核机制。

使用者应自行确认所在学校与课程对自动播放的允许范围，并对使用后果自负。作者不对因使用本工具导致的任何成绩、纪律或账号问题承担责任。

如果本项目无意侵犯了你的权益，请开 issue，会立即处理。

## License

[MIT](LICENSE)
