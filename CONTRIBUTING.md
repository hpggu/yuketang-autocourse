# 贡献指南

## 提 Issue 前

1. 先用 `-Once` 跑一遍，把输出贴上来：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\src\AutoCourse.ps1 -Once
   ```

2. 附上 `logs/autocourse-*.log` 的最后 100 行。
3. 说明：浏览器与版本（Edge 120 / Chrome 121…）、系统缩放比例（100% / 125% / 150%）、雨课堂域名（`changjiang.yuketang.cn` 等）、课程页面类型。

没有这三样信息的 issue 没法定位，因为本项目的所有失败几乎都来自「类名 / 坐标取不到」。

## 提 PR

- 改动请对应 [docs/REVIEW.md](docs/REVIEW.md) 里的条目编号，PR 描述里写明是 P0-x 还是 P1-x。
- 不要引入新的外部依赖（本项目坚持「只要 Windows 自带 PowerShell 就能跑」）。
- 新增日志一律走 `Write-CourseLog`，不要直接 `Write-Host`。
- 不要加入以下内容：
  - 修改播放倍速 / 静音 / 拖动进度条
  - 伪造进度上报、绕过平台检测
  - 自动答题、自动签到
  - 向任何服务器上报用户数据

  本项目的定位是「按正常速度把视频连着播完」，超出这条线的功能会被拒。

## 代码风格

- 函数名 `动词-名词`（PowerShell 规范），私有辅助函数加 `script:` 作用域变量
- 与 UI 元素交互的地方必须能容忍元素消失（`try/catch` + `continue`，并留一行日志）
- 注释写「为什么」，不写「是什么」

## 开发自测清单

- [ ] `-Once` 能正确读出课程名 / 当前时间 / 总时长
- [ ] `-NextNow` 能切到下一个视频，且跳过作业节点
- [ ] 手动暂停视频，脚本 5 秒内自动续播
- [ ] 播完一节后能自动进入下一节，日志有 `Entered lesson: ...`
- [ ] 双击停止后 3 秒内退出，`STOP_AUTOCOURSE` 标记被清掉
- [ ] 同时启动两次，第二次提示已有实例在运行
