# Scripts

个人 macOS 脚本与修补工具集合。

## 目录

```text
.
├── scripts/                    # 日常小工具
│   ├── media.sh                # 通用媒体转换（图片压缩/转换、视频转 GIF）
│   ├── docker                  # docker context 兼容包装
│   ├── docker-shim.sh          # 加载 docker-wrapper.sh
│   ├── docker-wrapper.sh       # docker 函数包装
│   ├── iterm2-recv-zmodem.sh   # iTerm2 接收 ZModem
│   └── iterm2-send-zmodem.sh   # iTerm2 发送 ZModem
├── userscripts/                # 油猴脚本（Tampermonkey / ScriptCat）
│   ├── fnos-danmaku.user.js    # 飞牛影视弹幕增强
│   ├── GREASYFORK.md           # Greasy Fork 发布说明
│   └── README.md
├── hp-printer-driver/          # HP 打印机驱动跨版本迁移
│   ├── README.md
│   ├── collect.sh              # 在驱动正常的机器上收集
│   └── install.sh              # 在装不上安装器的机器上还原
└── deepseek-harness-app/       # DeepSeek Harness App 启动修补
    ├── README.md
    ├── fix.sh
    └── dsh-app-wrapper
```

## 使用

### 媒体转换

`media.sh` 采用子命令形式，支持长短 flag（`-i`/`--input` 等）。

#### 图片格式转换与压缩（`convert`）

```bash
scripts/media.sh convert -i photo.jpg -s 200K -f avif          # 压缩到 200K
scripts/media.sh convert -i page.png -s 1M -f jpg -o out.jpg   # 指定输出
scripts/media.sh convert -i drawing.emf -s 200K -f webp        # EMF 转位图
scripts/media.sh convert -i drawing.emf -s - -f svg            # EMF 转 SVG（纯转换）
scripts/media.sh convert -i drawing.emf -s gzip -f svg         # EMF 转 .svgz（gzip）
scripts/media.sh convert -i ./images -s 100K -f jpg -o ./out   # 目录批量（含 EMF）
```

- 输入可为位图（jpg/jpeg/png/webp/heic/heif/avif）或 EMF/WMF 矢量图。
- `-s` 支持 `B`/`K`/`M`（如 `200K`、`1.5M`）；`-` 表示仅转换不压缩；`gzip` 仅用于 SVG 输出（生成 `.svgz`）。
- 输出格式：`jpg`/`avif`/`webp`/`heif`/`heic`/`svg`，默认 `jpg`。
- EMF/WMF 转位图时经 `emf2svg-conv` → `rsvg-convert` 栅格化后再压缩。

#### 视频转 GIF（`gif`）

```bash
scripts/media.sh gif -i video.mp4                             # 默认 10fps/600px
scripts/media.sh gif -i video.mp4 -f 15 -w 800                # 指定帧率/宽度
scripts/media.sh gif -i video.mp4 -s 2M                       # 自动调节到 2M
scripts/media.sh gif -i ./videos -s 1M -o ./gifs              # 目录批量
```

- 采用 `palettegen`/`paletteuse` 两遍法，色阶平滑。
- 指定 `-s` 时自动在帧率与宽度间权衡（优先保帧率），直至满足目标大小。

依赖 `ffmpeg` / `ffprobe`；heif/heic 还需要 `heif-enc`；EMF/WMF 转换需要 `emf2svg-conv` 和 `rsvg-convert`（`brew install libemf2svg librsvg`）。

### DeepSeek Harness App 修补

见 [deepseek-harness-app/README.md](deepseek-harness-app/README.md)。

```bash
cd deepseek-harness-app
./fix.sh
```

### HP 打印机驱动迁移

见 [hp-printer-driver/README.md](hp-printer-driver/README.md)。新 macOS 上官方安装器
被版本检查挡住时，从另一台驱动正常的机器把 `/Library/Printers/hp` 等目录搬过去。

```bash
cd hp-printer-driver
sudo bash collect.sh              # 在驱动正常的那台机器上收集
sudo bash install.sh <备份目录>    # 在新机器上还原，只写 /Library
```

### 飞牛影视弹幕

见 [userscripts/README.md](userscripts/README.md)。脚本通过油猴直接给飞牛影视网页播放器挂载 danmu-api 弹幕，无需反向代理。

### 新机器上挂到 PATH

```bash
git clone git@github.com:shlllshlll/Scripts.git ~/Projects/Scripts
ln -s ~/Projects/Scripts/scripts/* ~/bin/   # 确保 ~/bin 已在 PATH 中
```

或者直接在 shell rc 中：

```bash
export PATH="$HOME/Projects/Scripts/scripts:$PATH"
```

## 说明

- `iterm2-*.sh` 中使用了 Homebrew 的 `/opt/homebrew/bin/rz` / `sz`，非 macOS
  或非 Homebrew 环境需要自行调整。
- 原 `~/Projects/script/osc` 是 arm64 的 Go 二进制（OSC52 剪贴板工具），
  不适合作为脚本放进 Git，因此没有随仓库迁移；需要时可在原位置保留或自行构建。
