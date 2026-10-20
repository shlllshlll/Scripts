# 油猴脚本

这里存放个人使用的 Tampermonkey / ScriptCat 油猴脚本。

## 飞牛影视 · 弹幕增强

[`fnos-danmaku.user.js`](./fnos-danmaku.user.js)

发布到 Greasy Fork 的元数据与提交流程见 [GREASYFORK.md](./GREASYFORK.md)。

为飞牛影视（fnOS）网页播放器外挂弹幕，不需要 Docker 反向代理，也不修改飞牛原始页面。脚本直接运行在播放页中，通过 `GM_xmlhttpRequest` 访问 [danmu-api](https://github.com/huangxd-/danmu_api) 获取弹幕。

### 功能

- 自动匹配：读取飞牛 `play/info` 返回的标题、季、集，调用 danmu-api 的 `match` 接口。
- 手动搜索：在播放器设置列表里打开「弹幕」二级菜单 → 搜索番剧 → 选择剧集 → 加载；菜单样式与飞牛原生设置项一致。
- SPA 跟随：飞牛内切换视频、换集时自动重新初始化。
- 兼容飞牛新版签名：自动读取 `Trim-MC-token` Cookie，并按 fnOS Web 端的 `authx` 算法生成请求签名，不依赖页面内 fetch 拦截器。
- Canvas 弹幕：滚动 / 顶部 / 底部弹幕、行避让、同屏上限、点击弹幕暂停 3 秒。
- 完整设置窗口：API 地址、API Token、自动匹配、透明度、显示区域、字号、行距、速度、密度、同屏上限、时间偏移、描边、调试日志。
- 输入隔离：在设置窗口和弹幕搜索框里打字时，不会触发飞牛播放器的 `f` 全屏、空格播放等全局快捷键。
- 设置持久化：使用 `GM_getValue` / `GM_setValue` 保存；菜单命令「⚙ 飞牛弹幕设置」随时打开设置窗口。
- 纯前端：不代理视频流，不修改飞牛服务端，不依赖 localStorage 里的飞牛登录信息。

### 安装

#### 方式一：ScriptCat / Tampermonkey 手动添加

1. 打开 ScriptCat 或 Tampermonkey 的管理面板。
2. 新建脚本，把 [`fnos-danmaku.user.js`](./fnos-danmaku.user.js) 的内容完整粘贴进去并保存。
3. 打开飞牛影视网页（默认是 `http://NAS-IP:5666/v`），进入任意视频播放页。
4. 首次使用点击浏览器工具栏里的 ScriptCat 图标，选择「⚙ 飞牛弹幕设置」，填写 danmu-api 地址。

#### 方式二：ScriptCat CLI（需要浏览器里确认）

```bash
sctl install /Users/shihaolei/Projects/Scripts/userscripts/fnos-danmaku.user.js
```

命令会等待浏览器里的安装确认，确认后脚本才会写入 ScriptCat。

### 首次配置

打开设置窗口后填写：

| 配置项 | 说明 |
|---|---|
| danmu-api 地址 | 例如 `http://192.168.1.252:9321`。留空时自动使用当前 NAS 地址 + `9321` 端口。 |
| API Token | 对应 danmu-api 的 `TOKEN`。默认 `87654321` 可以留空；也可以直接把 Token 写进地址，例如 `http://192.168.1.252:9321/87654321`。 |
| 自动匹配 | 打开视频后自动按标题 / 季 / 集匹配。 |

填写后点「测试连接」，成功会显示耗时和搜索结果数；再点「保存并应用」触发当前视频重新匹配。

> danmu-api 的 Token 是 URL 路径的一部分，不是 `Authorization` 请求头。脚本会自动拼接为 `地址/Token/api/v2/...`。

### 使用

- 播放器控制栏「设置」列表里的「弹幕」项：点击进入播放器内的二级菜单（复用同一个设置弹层），内含「显示弹幕」开关、搜索框、自动匹配和搜索结果。
- 二级菜单左上角「‹」：返回播放器设置列表；按 Esc 也可以返回。
- 二级菜单右上角齿轮图标：打开完整的弹幕设置窗口（API 地址、Token、字号、透明度等）；字号最小可调到 10px。
- ScriptCat 菜单「💬 打开弹幕搜索」：自动打开播放器设置并进入同一个弹幕二级菜单，不再使用旧的独立搜索面板。
- 加载/匹配提示：复用播放器自己的 toast（semi-toast），不再额外显示脚本左下角提示，避免和播放器的“已自动跳转至上次观看的位置”等提示重复。
- 搜索番剧后点击条目查看剧集，再点某一集加载弹幕。
- 点击飘过的弹幕会暂停该条 3 秒并显示时间戳。
- 设置窗口里的显示参数立即生效并自动保存；API 地址需要点「保存并应用」。

### 适配说明

脚本默认匹配以下页面：

```text
*://*/v
*://*/v/*
```

覆盖飞牛影视的 `/v/video/<guid>` 播放页。如果你的飞牛影视挂在反向代理的子路径下（例如 `https://example.com/fn/v/...`），或者使用了不同的路由，请在脚本头部补充对应的 `@match` / `@include`。

飞牛影视播放器目前使用 `xgplayer`，脚本会查找 `div.xgplayer`（或包含 `xgplayer` 的容器）里的 `<video>`。如果后续播放器结构变化，需要在脚本的 `findPlayer()` 里调整选择器。

### 为什么用 Canvas

高密度弹幕的主流实现是 Canvas（B 站等播放器也使用 Canvas / WebGL 混合方案）。相比每条弹幕一个 DOM 节点：

- 数百上千条弹幕时没有大量 DOM 布局和合成开销；
- 文字宽度测量、行避让、碰撞检测都在同一个绘制上下文里完成；
- 只需要同步 `video.currentTime` 和 `requestAnimationFrame`。

代价是文字不可选中、需要自己做点击命中检测、要处理 DPR / 尺寸变化。当前脚本用 Canvas 绘制弹幕，用 Shadow DOM 承载设置与搜索 UI，并带纹理缓存；在 4K 高密度场景下如果遇到性能瓶颈，可以进一步限制画布 DPR 或改 WebGL。

### 与 fn-danmu 的区别

| | fn-danmu | 本脚本 |
|---|---|---|
| 运行方式 | Docker 反向代理，注入脚本到 HTML | 油猴脚本，直接运行在原始页面 |
| 访问地址 | 必须访问代理端口 | 继续访问飞牛原地址 |
| 视频流 | 经代理透传 | 完全不经过脚本 |
| 弹幕 API | 由代理 `/dm-api` 转发 | `GM_xmlhttpRequest` 直连 |
| 配置 | 环境变量 | 油猴 GM 存储 + 设置窗口 |
| 适用 | 电视 / 无扩展浏览器 | 已安装 ScriptCat / Tampermonkey 的浏览器 |

参考项目：[rgcaafe/fn-danmu](https://github.com/rgcaafe/fn-danmu)。

### ScriptCat MCP（可选）

如果使用 DeepSeek Harness，可以把它配置成 MCP 客户端，让 Agent 直接管理 ScriptCat 脚本。通用 MCP 配置：

```json
{
  "mcpServers": {
    "scriptcat": {
      "command": "/Users/shihaolei/.local/bin/sctl",
      "args": ["mcp", "--name", "dsh"]
    }
  }
}
```

DSH 的 desktop profile 使用 cordis 配置；对应片段（已写入 `~/.dsh/profiles/desktop/cordis.patch.yml`）：

```yaml
- id: mcp-scriptcat
  name: "@deepseek-ai/dsh-mcp-client"
  config:
    serverName: scriptcat
    transport: stdio
    command: /Users/shihaolei/.local/bin/sctl
    args: ['mcp', '--name', 'dsh']
    failOnStartupError: false
```

修改后需要重启 DSH，新的 `mcp__scriptcat__*` 工具才会出现。前提是 `sctl` 守护进程和 ScriptCat 扩展已连接：

```bash
sctl status
```

### 排查

- **设置列表里没有「弹幕」项**：确认当前 URL 是 `/v/video/...`，播放器已经渲染出 `<video>`，并且打开的是播放器控制栏的「设置」而不是「高级」页；刷新页面后再试。
- **测试连接失败**：先在浏览器直接打开 `http://NAS-IP:9321`，确认 danmu-api 正在运行；检查地址协议、端口和 Token。
- **自动匹配失败**：文件名可能不被 danmu-api 识别，改用播放器设置里的「弹幕」二级菜单手动选择剧集。
- **弹幕和画面不同步**：在设置里调整「时间偏移」，正数延后、负数提前。
- **调试**：设置中打开「调试日志」，在控制台查看 `[飞牛弹幕]` 前缀的输出。
