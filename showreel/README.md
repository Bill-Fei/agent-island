# Agent 灵动岛 · Quiet Power

30 秒、1920×1080、30 fps；13 段技法 + 4 秒品牌收尾。
所有画面由 `window.render(t)` 决定，无运行时随机数或逐帧累积状态。
Canvas 绘制 → Playwright 900 张无损 PNG → ffmpeg H.264 / AAC MP4。
原创 120 BPM 配乐与音效由 NumPy 生成，48 kHz 立体声；无外部素材。

## 复现

```sh
python3 music.py output/original-score.wav
node render.cjs stills
node render.cjs render
python3 verify.py
```

需要 Python / NumPy、Node / Playwright / Chromium、ffmpeg。
支持 `PLAYWRIGHT_MODULE` 指定已安装的 Playwright 绝对模块路径。
可用 `FFMPEG` 指定编码器绝对路径。
可用 `CHROME_BINARY` 指定浏览器；默认使用本机 /Applications/Google Chrome.app。
`output/` 被仓库既有忽略规则排除，源代码单独版本管理。

## 内容边界

视觉方案和逐段表见 DESIGN.md。所有 UI 为代码重绘演示，非实时录屏。
不展示真实任务信息，不仿制厂商 Logo，Agent 用字母占位。
只宣称现有 macOS 状态层能力；Claude Code 的单次审批明确提示需显式开启。
粒子、城市、液态和点云为宣传视觉技法，不代表产品执行能力。
25.5–26 秒配乐源文件全零静音，26 秒品牌重击，26.98 秒句点落地。

## 输出

- `output/Agent-Island-Quiet-Power-1080p.mp4`
- `output/original-score.wav` / `original-score.json`
- `output/stills/` — 每段最可见时刻的关键帧
- `output/frames/` — 完整 900 帧，支持再次编码
- `output/render-report.json` — 确定性、网络与渲染报告
- `output/verification.json` — 编码、节拍栅格、静音与关键帧检查
