# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [2.0.0] - 2026-11-15

**换掉实现方式：UI Automation → Chrome DevTools Protocol。**

1.1.1 在真机上启动即报「未找到包含播放器的浏览器窗口」。排查结论：当前 Edge（127.x）的无障碍树只暴露有语义 / 可聚焦的节点，播放器整块（含时间文本、播放按钮）根本不在树里，`xt_video_player` 一次都没出现过。这不是选择器写错，是路线不成立：

- msedge 窗口 Descendants=695，ControlType 只有 Text×396 / Group×169 / Button×53 / Pane×49 / ListItem×6 / Document×2，类名只有 `leaf-item`、`nav-item-title is-expand`、`el-input__inner`、`EdgeTab`；
- 视频区只存在一个无 name 的 `Intermediate D3D Window` Pane；
- 用 `--force-renderer-accessibility` 起临时 profile 也不暴露网页文本；
- `TextPattern.GetText` 直接 `System.AccessViolationException` 崩进程。

改用 CDP 后这些问题一次性消失。

### 变更

- **新传输层**：`/json/list` 选标签页 + `System.Net.WebSockets.ClientWebSocket` 连 `webSocketDebuggerUrl`，`Runtime.evaluate`（`returnByValue` + `awaitPromise`）在页面内执行 JS。
- **新状态源**：直接读 `video.currentTime` / `duration` / `paused` / `ended`，不再解析屏幕上的 `mm:ss` 文本，与窗口缩放、遮挡、DPI 无关。
- **不再抢鼠标**：1.x 需要 hover 播放器底部 0.9 秒让控制条浮出来读时间；2.0 完全不碰鼠标，浏览器可以最小化。
- **`NotAllowedError` 兜底**：`play()` 被自动播放策略拦下时，用 `Input.dispatchMouseEvent` 在播放器中央派发一次真实点击。
- **新参数**：`-Port`（默认 9222）、`-UrlMatch`（默认 `yuketang`）、`-EndToleranceSeconds`（默认 1.5）、`-Quiet`；删除 `-ProcessName`（不再靠进程名找窗口）。
- **断线重连**：WebSocket 断开后自动重连，不用重开脚本。
- **浮层探测**：每轮统计疑似测验 / 弹窗的浮层数量并写警告日志。
- **启动器**：`启动自动连播.cmd` → `启动刷课.cmd`，自动探测 9222 端口，未开则结束浏览器并用 `--remote-debugging-port=9222 --restore-last-session` 重启（会话恢复，登录态不丢）。
- 目录切换仍按 `.leaf-item` + 包含「视频」匹配，从当前高亮往后找第一个。

### 保留

- 单实例互斥量、`STOP_AUTOCOURSE` 停止标记、`logs\autocourse-*.log` 日志、`-Once` / `-NextNow` / `-MaxVideos` / `-MaxStuckPerLesson` / `-MaxStuckTotal` 语义不变。

### 实测

Edge 127.0.2651.74 + 长江雨课堂页面：`-Once` 读到 `CurrentTime 1:11 / Duration 10:34 / LeafCount 77 / ActiveLeaf 视频 1.1 可视化初识`；主循环被 `NotAllowedError` 拦下后点击恢复播放，14 秒后时间从 1:11 推进到 1:30。

## [1.1.1] - 2026-11-15

发布流水线修复，脚本本身行为不变。

### 修复

- 修正 `.github/workflows/ci.yml` 与 `release.yml` 的中文编码乱码，此前乱码导致「必需文件检查」必然失败、`Compress-Archive` 被打包前的注释行吞掉。
- CI 的必需文件检查不再硬编码中文 `.cmd` 文件名，改为按 `src` 下 `*.cmd` 数量校验。
- 打包步骤改为 `Get-ChildItem -Filter '*.cmd'` 复制，避免中文路径在不同 runner 上的编码差异。
- 新增 CI 编码检查：`src/AutoCourse.ps1` 必须带 UTF-8 BOM。
- 脚本内 `Version` 与 README 徽章同步为 1.1.1。

## [1.1.0] - 2026-11-15

把 [docs/REVIEW.md](docs/REVIEW.md) 里的 P0 / P1 问题全部修掉，行为更稳、排错更容易。

### 修复

- **兜底点击不再误伤其他程序**（P0-1）：`Invoke-Element` 走 `mouse_event` 前先比对 `GetForegroundWindow()`，再用 `WindowFromPoint` + `GetAncestor(GA_ROOT)` 确认点击坐标属于目标窗口，否则直接跳过并写日志。
- **目录节点识别不再漏掉带序号的视频**（P0-2）：「视频」标签由整串锚定 `^视频$` 改为包含匹配，`视频 1` / `视频(2)` 这类命名现在能正确识别，不会再出现「后面没有视频了」的假完成。
- **片尾停帧不再卡死**（P0-3）：除 `当前时间 >= 总时长 - 1` 外，新增「距片尾 3 秒内且时间连续 8 轮不推进」的完成兜底。
- **卡死不再无限空转**（P0-4）：新增分层升级 —— 本节卡住 `MaxStuckPerLesson` 次就尝试切下一节，全程累计 `MaxStuckTotal` 次则退出；不再因为计数被清零而跑一整晚。
- **单实例与停止逻辑用 `try/finally` 收尾**（P1-3）：异常中断、Ctrl+C、`exit` 都会释放互斥量并清理 `STOP_AUTOCOURSE`。

### 改进

- **UIA 读取带属性缓存**（P1-1）：`Get-CachedElements` 用 `CacheRequest` 一次性缓存 ClassName / Name / ControlType / BoundingRectangle 等属性，把每轮 4~5 次全树跨进程遍历压到 1 次；目录节点改为「leaf-item 矩形包含文本」的内存计算，不再每个节点单独 FindAll。
- **日志落盘**（P1-2）：每次运行写入 `logs\autocourse-yyyyMMdd-HHmmss.log`，控制台与文件同时输出。
- **浏览器进程名参数化**（P1-4）：`-ProcessName` 默认 `msedge, chrome`，不再写死 Edge。
- **新增 `-MaxVideos` / `-MaxStuckPerLesson` / `-MaxStuckTotal`**，可以限制一次跑几节、多久放弃。
- **`-Once` 自检输出扩充**：除时间与播放状态外，额外打印播放器类名、目录节点数、视频节点数，平台改版时可直接定位是哪个选择器失效。
- 移除死代码，所有平台选择器集中到脚本头部 `$script:*Pattern` 变量，改版只需改一处。
- 全部日志与注释改为中文，并统一为 UTF-8 BOM（PowerShell 5.1 按 ANSI 读取无 BOM 脚本会把中文读坏并导致正则失配）。

### 已知限制

- 视频中途弹出随堂测验 / 弹窗遮挡播放器时，「暂停就点播放」点不动，脚本只能计数并最终退出——这类课程仍需人工处理弹题。详见 README「已知限制」。

## [1.0.0] - 2026-10-22

首个可用版本。

- 通过 Windows UI Automation 定位 Edge 中的雨课堂播放器
- 自动续播暂停的视频
- 播放结束后按左侧目录顺序切到下一个视频节点，自动跳过作业 / 讨论题
- 平台自动跳转时跟随，避免重复点击
- 命名互斥量保证单实例
- `-Once` / `-NextNow` / `-PollSeconds` 三个命令行开关
- 双击式启动 / 停止脚本