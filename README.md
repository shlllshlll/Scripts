# Scripts

个人 macOS 脚本与修补工具集合。

## 目录

```text
.
├── scripts/                    # 日常小工具
│   ├── compress-image.sh       # 按目标大小压缩图片（ffmpeg）
│   ├── docker                  # docker context 兼容包装
│   ├── docker-shim.sh          # 加载 docker-wrapper.sh
│   ├── docker-wrapper.sh       # docker 函数包装
│   ├── iterm2-recv-zmodem.sh   # iTerm2 接收 ZModem
│   └── iterm2-send-zmodem.sh   # iTerm2 发送 ZModem
└── deepseek-harness-app/       # DeepSeek Harness App 启动修补
    ├── README.md
    ├── fix.sh
    └── dsh-app-wrapper
```

## 使用

### 图片压缩

```bash
scripts/compress-image.sh INPUT TARGET_SIZE FORMAT [OUTPUT]
scripts/compress-image.sh ./images 200K avif ./converted
```

依赖 `ffmpeg` / `ffprobe`；heif/heic 还需要 `heif-enc`。

### DeepSeek Harness App 修补

见 [deepseek-harness-app/README.md](deepseek-harness-app/README.md)。

```bash
cd deepseek-harness-app
./fix.sh --restart
```

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
