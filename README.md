# 雨课堂自动连播（Yuketang AutoCourse）

> 通过 Chrome DevTools Protocol 读取播放器状态，把雨课堂「学习空间」里的视频一个个连着放完：暂停就续播、播完自动进下一节。
> 不注入油猴脚本、不改倍速、不碰作业与测试。

<p align="left">
  <img alt="version" src="https://img.shields.io/badge/version-2.0.0-blue">
  <img alt="platform" src="https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4">
  <img alt="runtime" src="https://img.shields.io/badge/runtime-PowerShell%205.1%2B-5391FE">
  <img alt="browser" src="https://img.shields.io/badge/browser-Edge%20%2F%20Chrome-1B9AAA">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-green">
</p>

---

## 2.0 为什么换实现

1.x 用 Windows UI Automation 读页面，依赖浏览器把 DOM 暴露成无障碍树。实测当前 Edge（127.x）只暴露「有语义 / 可聚焦」的节点，**播放器整块不在无障碍树里**，于是脚本永远找不到 `xt_video_player`，一启动就报「未找到包含播放器的浏览器窗口」。

2.0 换成 CDP：浏览器开一个本地调试端口，脚本通过 WebSocket 在页面里执行 JS，直接读 `<video>` 的 `currentTime` / `duration` / `paused`，播完点目录里的下一节。

顺带解决 1.x 的三个代价：

| 1.x 的代价 | 2.0 的表现 |
| --- | --- |
| 抢鼠标（读时间要 hover 控制条） | 完全不碰鼠标 |
| 浏览器不能最小化 | 可以最小化 |
| 窗口遮挡 / 缩放影响识别 | 与窗口大小、缩放、遮挡无关 |

代价是多一步：浏览器必须带 `--remote-debugging-port` 启动。`启动刷课.cmd` 会自动处理这一步。

## 它做什么

| 能力 | 说明 |
| --- | --- |
| 自动续播 | 读 `video.paused`，暂停就调 `play()`；失败时通过 CDP 在播放器中央派发一次鼠标点击 |
| 卡住自愈 | `currentTime` 连续多轮不推进时记录并升级处理；本节超限就强制切下一节 |
| 自动下一节 | 播完后在左侧 `.leaf-item` 目录里找**后面第一个含「视频」的节点**并点击，自动跳过作业 / 讨论 |
| 片尾兜底 | 除 `ended` 外，`currentTime >= duration - 1.5s` 也按播完处理，不会停在最后一帧卡死 |
| 断线重连 | WebSocket 掉线后自动重连，不用重开脚本 |
| 弹窗提示 | 页面上出现疑似测验 / 弹窗时写警告日志，提醒你去看一眼 |
| 可随时停 | 双击 `停止自动连播.cmd`，或在窗口里按 `Ctrl+C` |
| 单实例保护 | 命名互斥量，双击两次不会互相抢 |
| 日志留痕 | 每次运行写 `logs\autocourse-*.log` |

## 它不做什么

- 不改播放倍速、不静音、不拖动进度、不伪造播放上报
- 不答题、不签到，不处理视频中途弹出的随堂测验
- 不处理作业、讨论题、考试
- 不绕过任何平台检测，也不保证进度被平台记为「已完成」

> 它只负责「把视频按原速连续播下去」。

---

## 快速开始

### 环境

- Windows 10 / 11
- PowerShell 5.1（系统自带，不需要 PowerShell 7）
- Microsoft Edge 或 Chrome

### 获取方式

- **下载打包版（推荐）**：到 [Releases](https://github.com/hpggu/yuketang-autocourse/releases/latest) 下载 `YuketangAutoCourse-x.y.z.zip`，解压到任意目录，双击 **`启动刷课.cmd`**（打包版是扁平结构，没有 `src` 这一层）。
- **使用源码**：克隆仓库后运行 `src\启动刷课.cmd`。

### 步骤

1. 用浏览器打开雨课堂「学习空间」，**登录**，进入课程，点开任意一个视频，确认播放器加载出来（能看到时间）。
2. 双击 `启动刷课.cmd`。它会先检查 9222 端口：
   - 端口没开 → 结束浏览器进程，用 `--remote-debugging-port=9222 --restore-last-session` 重新启动，标签页会被浏览器自己恢复（登录态不丢）；
   - 端口已开 → 直接进下一步。
3. 脚本连接上匹配 `yuketang` 的标签页后开始接管，日志里出现「已接管」即成功。
4. 要停：双击 `停止自动连播.cmd`，或在黑窗口里按 `Ctrl+C`。

> 第一次用请先跑 `-Once` 确认能读到状态，再跑正式模式。

### 命令行参数

```powershell
# 默认：每 2 秒检查一次，一直跑到没有下一个视频
powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1

# 只报告一次当前状态，不动页面（排查问题先用这个）
powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1 -Once

# 立刻切到下一节视频
powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1 -NextNow

# 换端口 / 换浏览器标签页关键字
powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1 -Port 9333 -UrlMatch 'yuketang|gdufemooc'

# 只放完 3 个视频就停
powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1 -MaxVideos 3
```

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Port` | `9222` | 浏览器远程调试端口 |
| `-PollSeconds` | `2` | 轮询间隔（秒） |
| `-Once` | — | 只打印一次状态就退出 |
| `-NextNow` | — | 立刻切到下一节视频后退出 |
| `-UrlMatch` | `yuketang` | 用哪个正则挑标签页 |
| `-MaxVideos` | `0` | 本次最多播放几节，`0` 不限制 |
| `-MaxStuckPerLesson` | `20` | 同一节卡住多少次后强制切下一节 |
| `-MaxStuckTotal` | `60` | 全程累计卡住多少次后退出 |
| `-EndToleranceSeconds` | `1.5` | 距片尾多少秒算播完 |
| `-Quiet` | — | 不往控制台打印，只写日志 |

`-Once` 实际输出：

```
Version      : 2.0.0
Transport    : CDP / WebSocket (port 9222)
PageTitle    : 学习空间
PageUrl      : https://changjiang.yuketang.cn/ai-workspace/lms-graph/.../video/...
ActiveLeaf   : 视频 1.1 可视化初识
LeafCount    : 77
CurrentTime  : 1:30
Duration     : 10:34
IsPlaying    : True
IsComplete   : False
ReadyState   : 4
PlaybackRate : 1
VideoSize    : 1151x405
Overlays     : 0
```

排错先看这几项：`LeafCount` 为 0 说明目录节点选择器变了；`VideoState` 显示没找到 `<video>` 说明标签页不是视频页或还没加载；`Overlays` 不为 0 说明有浮层。

---

## 工作原理

1. `GET http://127.0.0.1:9222/json/list` 拿到所有标签页，按 `-UrlMatch` 选第一个匹配的，取它的 `webSocketDebuggerUrl`。
2. 用 `System.Net.WebSockets.ClientWebSocket` 连上去，发 `Runtime.evaluate`（`returnByValue:true, awaitPromise:true`）在页面里执行一小段 JS。
3. 状态脚本返回 `currentTime` / `duration` / `paused` / `ended` / 当前高亮目录节点 / 疑似浮层数量。
4. 暂停 → 执行 `video.play()`；抛 `NotAllowedError` 时改用 `Input.dispatchMouseEvent` 在播放器中央按一下。
5. 播完 → 在 `.leaf-item` 列表里从当前高亮往后找第一个含「视频」的节点，`scrollIntoView` 后 `click()`。
6. 因为走的是浏览器调试协议而不是 DOM 注入，**不需要油猴、不需要改网页、不需要证书**；但需要浏览器带调试端口启动。

### 已知限制

- **只认 Chromium 系桌面浏览器**（Edge / Chrome），Firefox 没有同款协议。
- **需要调试端口**：已经在跑的浏览器没法事后开启，必须重启一次（`启动刷课.cmd` 会做）。
- **接管的是「一个标签页」**：选中的那个标签页不能被关掉、不能手动跳到别的页面，否则状态读不到。
- **同一个浏览器建议只开一个雨课堂标签页**，多个标签页时按 `-UrlMatch` 取第一个。
- **弹题遮挡仍然需要人**：视频中途弹出随堂测验时，页面被浮层盖住，`play()` 可能被拦、点击也落在浮层上，脚本只能计数并最终跳过或退出。
- **不保证平台判定「已完成」**：有的课程要求页面保持前台或有人脸 / 摄像头校验，脚本不处理这些。

---

## 常见问题

**启动就报「端口 9222 上没有可用的调试接口」**
浏览器不是用调试端口启动的。用 `启动刷课.cmd` 启动，或者手动执行：
`"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --remote-debugging-port=9222 --restore-last-session`

**报「没有找到匹配 'yuketang' 的标签页」**
调试端口开着但没开雨课堂页面。日志里会列出当前所有标签页 URL，照着把视频页开出来，或用 `-UrlMatch` 换个关键字。

**能连上但提示「当前页面还没有 `<video>` 元素」**
标签页还停在目录页 / 加载中。点开一个视频，或在脚本里等它自己加载完。

**日志里出现「play() 失败（NotAllowedError）」**
浏览器的自动播放策略或页面浮层拦住了。脚本会退回点击播放器中央；如果仍不行，先手动点一下播放，之后脚本就能接手。

**视频播完没自动跳下一节**
看 `-Once` 里的 `ActiveLeaf` / `LeafCount`。目录节点选择器 `.leaf-item` 变化时 `LeafCount` 会是 0 或明显变小，属于平台改版，需要更新选择器。

**能跑但一直提示「页面上有 N 个疑似弹窗」**
多半是随堂测验或提示框。手动处理掉，脚本会自动继续。

**想看这次到底发生了什么**
打开 `logs\autocourse-<时间戳>.log`，每次运行一个文件。

---

## 目录结构

```
yuketang-autocourse/
├── src/
│   ├── AutoCourse.ps1        # 主脚本（CDP）
│   ├── 启动刷课.cmd          # 双击启动（自动补调试端口）
│   ├── 停止自动连播.cmd      # 双击停止
│   └── logs/                 # 运行日志（自动生成，不进版本库）
├── docs/
│   ├── USAGE.md              # 详细使用说明
│   └── REVIEW.md             # 1.x 的评审记录与改进路线（历史文档）
├── .github/
│   ├── ISSUE_TEMPLATE/
│   └── workflows/
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

## 免责声明

本项目是**个人学习辅助工具**，只做「播放 / 切下一节」两件事，不修改平台数据、不伪造学习记录、不绕过任何考核机制。

使用者应自行确认所在学校与课程对自动播放的允许范围，并对使用后果自负。作者不对因使用本工具导致的任何成绩、纪律或账号问题承担责任。

如果本项目无意侵犯了你的权益，请开 issue，会立即处理。

## License

[MIT](LICENSE)
