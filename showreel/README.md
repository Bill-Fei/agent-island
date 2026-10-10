# Agent 灵动岛 · Quiet Power

30 秒、1920×1080、30 fps；13 段技法 + 4 秒品牌收尾。
所有画面由 `window.render(t)` 决定，无运行时随机数或逐帧累积状态。
Canvas 绘制 → Playwright 900 张无损 PNG → ffmpeg H.264 / AAC MP4。
原创 120 BPM 配乐与音效由 NumPy 生成，48 kHz 立体声；无远程素材。
V3 在 V2 基础上使用已安装应用真实图标，以及项目存档的真实操控页面。

## 复现

```sh
python3 prepare_assets.py
python3 music.py output/v3/original-score.wav
node render.cjs stills
node render.cjs render
python3 verify.py
```

需要 Python / NumPy、Node / Playwright / Chromium、ffmpeg。
支持 `PLAYWRIGHT_MODULE` 指定已安装的 Playwright 绝对模块路径。
可用 `FFMPEG` 指定编码器绝对路径。
可用 `CHROME_BINARY` 指定浏览器；默认使用本机 /Applications/Google Chrome.app。
`output/` 被仓库既有忽略规则排除，源代码单独版本管理。

## V3 修订

- Claude / Codex / WorkBuddy / 豆包图标提取自本机已安装应用，不再使用 CL/C/W/D 占位。
- 三态展示、设置、尺寸预览、Agent 接入、任务详情使用真实产品截图。
- 完整任务总览等比呈现，不调整原有 UI 列位；标题、URL、会话标识做明显遮挡。
- 设置与游标仅示意操作，未执行接入/批准/真实任务操作，未声称实时录屏。
- 绿色团块加岛替换成银白元球聚合；全片背景减少绿色染色。
- 配乐重写为《Light Motion》：大调玻璃拨音、轻切分、圆润低频；保持 120 BPM。
- V1 MP4 与配乐原样保留，新版独立输出到 `output/v2/`。
- 开场先展示真实小态，再进入弹跳信号；真实页面按比例放大并加入局部焦点镜头。
- 每段收敛为主标题 + 产品动作；液态元球最终形成岛形轮廓；网格段改为浅灰瓷白。
- 统一转场的圆角 / 横向收拢语言；在设置、悬停、打开应用节点加入 NumPy 生成的轻触感音效。

## 内容边界

视觉方案和逐段表见 DESIGN.md。V3 使用 2026-10-08 存档真实界面，非实时录屏。
不仿制厂商 Logo，不读取运行时日志；会话相关信息在复制素材中脱敏，源图不改。
素材提取来源与处理记录见 `output/v2/assets/manifest.json`。
只宣称现有 macOS 状态层能力；未展示无真实截图支撑的审批弹层。
粒子、城市、液态和点云为宣传视觉技法，不代表产品执行能力。
25.5–26 秒配乐源文件全零静音，26 秒品牌重击，26.98 秒句点落地。

## 输出

- `output/v3/Agent-Island-Quiet-Power-V3-1080p.mp4`
- `output/v3/original-score.wav` / `original-score.json`
- `output/v3/stills/` — 每段最可见时刻的关键帧
- `output/v3/frames/` — 完整 900 帧，支持再次编码
- `output/v3/render-report.json` — 确定性、网络与渲染报告
- `output/v3/verification.json` — 编码、节拍栅格、静音与关键帧检查
