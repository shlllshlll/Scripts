# Scripts

个人 macOS 脚本与修补工具集合。

## 目录

```text
.
├── scripts/                    # 日常小工具
│   ├── media.sh                # 通用媒体转换（图片、视频转 GIF、视频格式互转、音频提取）
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
- `-s` 的 `K`/`M`/`G` 按 macOS 的 1:1000 计算（`200K`=200000 字节），二进制请写 `KiB`/`MiB`/`GiB`；`-` 表示仅转换不压缩；`gzip` 仅用于 SVG 输出（生成 `.svgz`）。
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

#### 视频格式转换与压缩（`video`）

```bash
scripts/media.sh video -i movie.mp4 -f wmv                # mp4 转 wmv（Windows 播放，高画质）
scripts/media.sh video -i movie.mp4 -f wmv -s 200M        # 同时压到约 200M
scripts/media.sh video -i movie.mp4 -f wmv -q 4           # 画质稍降、体积更小
scripts/media.sh video -i movie.mkv -f mp4 --copy         # 无损换容器（秒完成）
scripts/media.sh video -i clip.mov -f mp4 -q 20 -r 1080p  # 指定画质与分辨率
scripts/media.sh video -i clip.mov -f webm -b 2M          # 指定视频码率
scripts/media.sh video -i movie.mp4 -f mkv --codec h265 -q 22  # 用别名指定编码器
scripts/media.sh video -i movie.mp4 -f webm --codec vp9   # VP9 进 webm
scripts/media.sh video -i ./videos -f wmv -o ./wmv        # 目录批量
```

- 每次转换前先打印源文件摘要（大小/时长/编码/分辨率/帧率/码率/音轨），便于核对参数。
- 目标格式：`mp4`/`m4v`/`mov`/`mkv`/`webm`/`avi`/`wmv`/`flv`/`ts`/`mpg`；也可由 `-o` 的扩展名推断。
- 默认保持原分辨率、帧率与时长；容器支持且未指定压缩参数时自动流复制（不重编码、无画质损失），否则按高画质重编码（x264 CRF 18、WMV8 qscale 2、VP9 CRF 32 等）。`--copy` 可强制流复制，`-s -` 显式表示只换格式不压缩。
- 压缩方式三选一：`-s` 目标大小（按码率反推，x264/VP9/MPEG-4 走两遍编码）、`-b` 指定码率、`-q` 指定 CRF/qscale；都不给即高画质模式。
- 视频编码器可显式指定：`--codec` 接受别名（`h264`/`h265`/`h266`/`av1`/`vp8`/`vp9`/`prores`/`mpeg4`/`mpeg2`/`wmv2`，加 `_hw` 后缀用硬件编码如 `h265_hw`，`auto` 表示容器默认）或 ffmpeg 编码器原名（`libx265`、`libsvtav1`）。别名按**本机 ffmpeg 实际能力**解析，`video --help` 会动态列出可用编码；容器装不下的组合（webm+h265、mpg+h264 等）在开始编码前就报错。H.266 需要 ffmpeg 编译时启用 `libvvenc`，Homebrew 版没有。
- mp4/mov 中的 HEVC 自动打 `hvc1` 标签，macOS 原生播放器可直接播放；硬件编码（`h264_hw`/`h265_hw`）的 `-q` 为 0-100、越大越清晰。
- `-r 1080p`/`-r 1280x720` 缩放，`--fps` 改帧率；重编码统一 8bit `yuv420p`，兼容 Windows 等平台播放器。
- 音频默认 `-a auto`（能复制则复制，否则按容器转码：wmv→wma、webm→opus、avi→mp3）；`-a 192k` 指定码率，`-a none` 去掉音轨。
- 音频编码可单独指定：`--acodec`（aac/mp3/opus/vorbis/flac/alac/ac3/eac3/mp2/wma/pcm）、`--abitrate`、`--ar` 采样率、`--ac` 声道数；容器不支持时会报错（例如 wmv 只能用 wma）。mkv 支持 flac/opus/ac3，mp4 支持 aac/mp3/ac3/alac。
- 仅保留首条视频轨和首条音频轨，字幕与其余音轨不随转换保留。
- `wmv` 使用 FFmpeg 的 WMV8（`wmv2`）+ WMA2（`wmav2`），Windows Media Player 可直接播放；FFmpeg 没有 WMV9（`wmv3`）编码器。源超过 1080p 时会提示兼容性风险（可加 `-r 1080p`）。WMV8 编码为单线程，长视频转换会偏慢，编码时出现 `rc buffer underflow` 警告属正常现象。
- `-s` 先按目标码率编码；若编码器码率控制较弱（如 `wmv2`），会先用 12 秒片段试算并自动校准码率，仍压不下去时自动降低分辨率/帧率（1 分钟视频也会先试算）。`--no-adapt` 可关闭自动降分辨率/帧率。
- `-s` 的 K/M/G 按 1:1000 计算，整体误差一般小于 5%；`wmv2` 实际码率常高于设定值，试算会自动修正。

#### 交互式选择压缩方案（`video -I`）

```bash
scripts/media.sh video -i movie.mp4 -f wmv -s 400M -I
```

先试算并列出多组方案（分辨率 / 帧率 / 视频码率 / 预计大小 / 是否达标），可直接输入编号，
也可用 `r720`、`f24`、`b5000k`、`s150M` 调整后再确认：

```text
可选方案（目标 400.0 MB，源 1.20 GB）:
  [1] 1080p@24fps    视频 7800kbps  预计 420.0 MB 超出目标
  [2]  720p@30fps    视频 6900kbps  预计 395.0 MB 符合目标
  [3]  480p@30fps    视频 4200kbps  预计 300.0 MB 符合目标
当前方案: 720p@30fps 视频 6900kbps，预计 395.0 MB（符合目标）
选择编号，或输入 r720 / f24 / b5000k / s150M 调整；回车=确认，a=重算，q=退出:
```

- 不指定 `-s` 时会先询问目标大小（回车则按高画质转换）。
- `r720` 改分辨率、`f24` 改帧率、`b5000k` 改码率、`s150M` 改目标大小；回车确认，`a` 重新试算，`q` 退出。
- 交互模式不能与 `-b/-q/-r/--fps/--copy/--no-adapt` 或目录批量同时使用。

#### 查看媒体信息（`info`）

```bash
scripts/media.sh info -i movie.mp4
scripts/media.sh info movie.mp4
```

- 显示容器、大小、时长、总码率、轨道数量，以及视频编码/分辨率/帧率/像素格式/码率、音频编码/采样率/声道/码率。
- 自动给出 `80% ≈ -s 1.14M`、`50% ≈ -s 710K`、`30% ≈ -s 426K` 等参考值，方便决定压缩参数。

#### 音频提取与转换（`audio`）

```bash
scripts/media.sh audio -i movie.mp4                  # 提取为 m4a（aac 源直接复制）
scripts/media.sh audio -i movie.mp4 -f mp3 -b 320k   # 转 mp3 320k
scripts/media.sh audio -i movie.mkv -f flac          # 转无损 flac
scripts/media.sh audio -i movie.ts -f wav --ac 1     # 单声道 wav
scripts/media.sh audio -i song.flac -f opus --ar 48000 --ac 2
scripts/media.sh audio -i ./videos -f mp3 -o ./audio # 目录批量
```

- 输入可以是视频或音频，只提取第一条音频流（画面、字幕丢弃）。
- 输出格式：`m4a`/`mp3`/`aac`/`flac`/`wav`/`opus`/`ogg`/`wma`/`ac3`/`mka`，默认 `m4a`；也可由 `-o` 的扩展名推断。
- 默认能流复制就复制（如 aac → m4a），否则按格式默认编码器转码；`--copy` 强制复制，`--acodec` 强制指定编码器。
- `-b` 指定码率（无损格式忽略并提示），`-s` 指定目标大小（按码率反推，K/M/G 为 1:1000，`-` 表示不压缩），`--ar` 采样率，`--ac` 声道数。
- 采样率/声道超出编码器能力会报错；未指定时自动降到编码器上限（如 mp3 最高 48kHz/2 声道、opus 固定 48kHz）。

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
