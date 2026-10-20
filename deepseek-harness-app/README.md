# DeepSeek Harness App + dsh 启动修补

这个目录解决的是 **native macOS 版 `DeepSeek Harness App`**（bundle id
`ai.deepseek.DeepSeekHarnessApp`，位于 `/Applications/DeepSeek Harness App.app`）
启动本地 dsh 服务失败的问题：

```text
本地服务在就绪前以状态 1 退出。

/Users/xxx/Library/pnpm/bin/dsh:2
# Resolve $0 through symlinks so basedir is the shim's real directory.
^

SyntaxError: Invalid or unexpected token
```

> 注意：这不是 Electron 版的 `DeepSeek Harness.app`（bundle id `com.deepseek.dsh`）。
> 两者可以同时安装，本修补只针对前者。

## 根因

有三层，缺一不可：

1. **App 调用方式**
   App 通过登录 shell 探测 `command -v dsh`，拿到路径后执行的是：

   ```text
   node <dsh 路径>
   ```

   而 pnpm / npm 在 Unix 上安装的 `dsh` 是 `#!/bin/sh` 包装脚本，Node 把它当
   JavaScript 解析，于是报 `SyntaxError`。

2. **dsh 版本太旧**
   旧版 `@deepseek-ai/dsh@0.1.2-rc.1` 的插件树在启动时会报大量
   `Cannot find package ...`，而且这个 App 需要的是 0.2.x 系列。

3. **pnpm 的 isolated 布局**
   dsh 0.2.x 启动时需要原生模块
   `node-addon-require-builtin-darwin-arm64`。pnpm 默认的 isolated
   `node_modules` 布局会让它解析不到，报：

   ```text
   No usable native binding found for node-addon-require-builtin-darwin-arm64 (auto)
   ```

   用 `node-linker=hoisted` 安装即可。

## 一键安装

```bash
git clone git@github.com:shlllshlll/Scripts.git
cd Scripts/deepseek-harness-app
./fix.sh
```

然后完全退出 App（Cmd+Q）再打开。

如果希望脚本尝试自动退出并重开（需要 macOS 自动化权限）：

```bash
./fix.sh --restart
```

如果系统拒绝自动化请求，脚本会提示你手动 Cmd+Q，不会用 `killall` 强杀。

脚本会自动：

- 检查 macOS、Node.js 22.19+、pnpm/npm；
- 用 pnpm 安装 `@deepseek-ai/dsh@0.2.1-rc.2`，并加
  `--config.node-linker=hoisted`；没有 pnpm 时退回 npm；
- 把 `dsh-app-wrapper` 安装到 `~/.dsh/app-bin/dsh`，权限 `0755`；
- 在登录 shell 的 rc 文件（zsh 是 `~/.zshrc`，bash 是 `~/.bash_profile`）
  中写入带标记的 PATH 块，只对 App 生效；
- 修改前备份原 rc 文件，重复运行会自动替换旧块，不会重复追加；
- 输出自检结果。

## 手动版（便于审查）

### 1. 安装 dsh

```bash
pnpm add -g @deepseek-ai/dsh@0.2.1-rc.2 --config.node-linker=hoisted
```

确认：

```bash
dsh -V          # 0.2.1-rc.2
```

如果使用 npm，也可以：

```bash
npm install -g @deepseek-ai/dsh@0.2.1-rc.2
```

npm 的扁平布局没有 pnpm 的原生模块解析问题，但 `dsh` 仍然是 shell shim，
所以下面的 JS 启动器仍然需要。

### 2. 安装 JS 启动器

```bash
mkdir -p ~/.dsh/app-bin
install -m 755 dsh-app-wrapper ~/.dsh/app-bin/dsh
```

启动器做的事情：

- 读取 pnpm/npm shim 里的 `# cmd-shim-target=...`，找到真正的
  `@deepseek-ai/dsh/lib/bin.js`；
- 用 `process.execve()` 原地替换成 `node <真正的 bin.js> ...`，保持 PID 和
  命令行不变，App 能正常识别、停止服务；
- 如果拿不到 shim target，回退到 `/bin/sh <shim>` 或普通子进程；
- 支持 `DSH_APP_REAL_CLI` 环境变量和 `~/.dsh/app-bin/dsh-target` 手动覆盖。

### 3. 让 App 的登录 shell 优先找到启动器

在 `~/.zshrc`（bash 用户放 `~/.bash_profile`）末尾加入：

```zsh
# >>> deepseek-harness-app shim >>>
# DeepSeek Harness App runs `node <command -v dsh>`, but pnpm's dsh is a
# /bin/sh shim. Prepend a real JS launcher for this GUI app only.
if [[ "${__CFBundleIdentifier:-}" == "ai.deepseek.DeepSeekHarnessApp" ]] \
    || [[ "${XPC_SERVICE_NAME:-}" == *"ai.deepseek.DeepSeekHarnessApp"* ]]; then
  export PATH="$HOME/.dsh/app-bin:$PATH"
elif [[ ! -t 0 && ! -t 1 ]] \
    && [[ "$(ps -o comm= -p "${PPID}" 2>/dev/null)" == *"DeepSeekHarnessApp"* ]]; then
  export PATH="$HOME/.dsh/app-bin:$PATH"
fi
# <<< deepseek-harness-app shim <<<
```

两个判断分支的原因：

- 第一个分支：App 由 LaunchServices 启动时，环境里通常有
  `__CFBundleIdentifier` / `XPC_SERVICE_NAME`，判断最快；
- 第二个分支：App 的探测 shell 如果过滤了环境变量，就通过 `$PPID` 看父进程；
  `! -t 0 && ! -t 1` 保证只在 App 的非交互探测 shell 里执行 `ps`，不影响普通终端。

普通终端不会命中条件，`command -v dsh` 仍然是 pnpm 的 shim。

> `fix.sh` 自动处理 zsh（`~/.zshrc`）和 bash（`~/.bash_profile`）。
> 如果登录 shell 是 fish，需要把同样的判断写进 `~/.config/fish/config.fish`
> （fish 的 `if` 语法不同，思路相同）。

## 验证

```bash
# 1. 启动器本身
~/.dsh/app-bin/dsh -V
# 0.2.1-rc.2

# 2. App 视角下解析到的 dsh
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm-256color \
  __CFBundleIdentifier=ai.deepseek.DeepSeekHarnessApp \
  /bin/zsh -ilc 'command -v dsh'
# /Users/xxx/.dsh/app-bin/dsh

# 3. 普通终端仍然是 pnpm shim
zsh -ilc 'command -v dsh'
# /Users/xxx/Library/pnpm/bin/dsh

# 4. 服务是否起来
tail -n 20 ~/Library/Logs/DSHMac/server-$(date +%F).log
# 看到: dsh web: http://127.0.0.1:3080/?token=...
lsof -nP -iTCP:3080 -sTCP:LISTEN
```

日志是追加写入的，开头可能还留着上一次失败的 `SyntaxError`；往下找新的
`dsh web: ...` 行即可。

## 更新 dsh

- 通过 **pnpm** 更新：启动器会自动跟随新的 `cmd-shim-target`，不需要改包装脚本。
  ```bash
  pnpm add -g @deepseek-ai/dsh@<version> --config.node-linker=hoisted
  ```
- 通过 **npm** 安装到其他位置：启动器也会扫描常见 npm 全局目录；如果仍有问题，
  写一个绝对路径到 `~/.dsh/app-bin/dsh-target`，或设置：
  ```bash
  export DSH_APP_REAL_CLI=/path/to/@deepseek-ai/dsh/lib/bin.js
  ```

## 可选：更新 dsh-git-rollback 插件

旧版 `dsh-git-rollback@0.1.7` 的 `peerDependencies` 只接受 dsh 0.1.x，
dsh 0.2.1 会主动禁用它：

```text
disabling profile plugin row "git-rollback": Plugin dsh-git-rollback@0.1.7
is incompatible with dsh 0.2.1-rc.2
```

新版 `0.1.12`（`Jager.dsh-vscode` 0.13.57 内置）的 peer 是
`>=0.1.0-rc.6`，可以配合 dsh 0.2.1。更新步骤：

```bash
# 1. 从扩展 VSIX 或扩展仓库的 resources/dsh-git-rollback 取得 0.1.12

# 2. 放到一个稳定目录
mkdir -p ~/.dsh/plugins
cp -R /path/to/dsh-git-rollback ~/.dsh/plugins/dsh-git-rollback-0.1.12

# 3. 修改 ~/.dsh/profiles/web/package.json，把 dsh-git-rollback 改成：
#    "dsh-git-rollback": "file:/Users/you/.dsh/plugins/dsh-git-rollback-0.1.12"
#    注意这里必须是绝对路径，不能用 ~

# 4. 让 profile 的 node_modules 指向新目录
rm -rf ~/.dsh/profiles/web/node_modules/dsh-git-rollback
ln -s ~/.dsh/plugins/dsh-git-rollback-0.1.12 \
      ~/.dsh/profiles/web/node_modules/dsh-git-rollback

# 5. 更新 lockfile
cd ~/.dsh/profiles/web
pnpm install --lockfile-only --ignore-scripts

# 6. 完全退出并重开 DeepSeek Harness App
```

只在使用 `web` profile 的 `git-rollback` 插件时需要做这一步；其他 profile
不受影响。更新前建议备份 `~/.dsh/profiles/web/package.json` 和
`node_modules/dsh-git-rollback`。

## 回滚

```bash
# 1. 删除 rc 文件中的标记块（# >>> deepseek-harness-app shim >>> 到
#    # <<< deepseek-harness-app shim <<<），或者恢复最近一次 .bak 备份。
# 2. 删除启动器
rm -f ~/.dsh/app-bin/dsh

# 3. 可选：把 pnpm 全局 dsh 降回旧版（不推荐，旧版本身是坏的）
pnpm add -g @deepseek-ai/dsh@0.1.2-rc.1
```

## 常见问题

### 启动日志里仍有 `Module._compile` / `SyntaxError`

说明 App 还在用旧的 PATH 缓存或旧进程：

1. 完全退出 App（Cmd+Q，确认 Dock 里没有残留）；
2. 确认上面的“App 视角”验证输出是 `~/.dsh/app-bin/dsh`；
3. 重新打开 App。

### `disabling profile plugin row "git-rollback"`

这是非致命警告：`dsh-git-rollback@0.1.7` 与 dsh 0.2.x 不兼容，dsh 会主动禁用它。
如果还需要这个插件，请升级对应的 VSCode 扩展/插件到兼容 0.2.x 的版本。

### `No usable native binding found`

说明 dsh 不是用 hoisted 布局安装的。重新执行：

```bash
pnpm add -g @deepseek-ai/dsh@0.2.1-rc.2 --config.node-linker=hoisted
```

### Node 版本

需要 Node.js 22.19+ 或 24+。`fix.sh` 会检查；如果版本太低，先用 nvm 切换。

### 这个修补会不会影响普通终端的 `dsh`？

不会。只有 App 的登录 shell（以及它启动的服务子进程）会拿到
`~/.dsh/app-bin`；普通交互终端的 `command -v dsh` 仍然是 pnpm 的 shim。
