# 发布到 Greasy Fork

这个目录里的 [`fnos-danmaku.user.js`](./fnos-danmaku.user.js) 可以直接作为 Greasy Fork 脚本提交。

## 建议填写的信息

| 字段 | 内容 |
|---|---|
| Script name | `飞牛影视 · 弹幕增强` |
| English name | `fnOS Video Danmaku` |
| Description | 为飞牛影视（fnOS）网页播放器挂载 danmu-api 弹幕：自动匹配、手动搜索、播放器内二级菜单和完整设置窗口，无需反向代理。 |
| Category | `Video`（如果没有 Video，选 `Other`） |
| License | `MIT` |
| Tags | `飞牛`, `fnOS`, `弹幕`, `danmaku`, `影视`, `NAS` |
| Homepage | `https://github.com/shlllshlll/Scripts` |
| Support | `https://github.com/shlllshlll/Scripts/issues` |

## 提交方式

### 方式一：从 GitHub 原始地址导入（推荐）

先把本仓库 push 到 GitHub，确认仓库是公开的，然后使用：

```text
https://raw.githubusercontent.com/shlllshlll/Scripts/main/userscripts/fnos-danmaku.user.js
```

在 Greasy Fork 的「Post a new script / 提交脚本」页面选择从 URL 导入（或把上面的地址粘贴到源码/导入地址），确认元数据后发布。

> 如果仓库是私有的，原始地址无法访问，请改用方式二。

### 方式二：直接粘贴源码

打开 Greasy Fork 的「Post a new script / 提交脚本」页面，把 [`fnos-danmaku.user.js`](./fnos-danmaku.user.js) 的完整内容粘贴到源码框，填写上面的信息后发布。

## 更新版本

1. 修改脚本里的 `@version`（和 `const VERSION`）；
2. push 到 GitHub；
3. 在 Greasy Fork 脚本页面使用「Update script / 同步」：
   - 如果配置了从 URL 同步，直接同步；
   - 否则重新粘贴/上传新版本源码。

`@downloadURL` / `@updateURL` 不建议写 GitHub 原始地址，交给 Greasy Fork 自己管理，否则两套更新源会冲突。

## 审核说明（可粘贴到脚本描述里）

```text
脚本说明：
- 仅作用于飞牛影视（fnOS）的 /v 和 /v/video/* 页面，通过播放器设置里的「弹幕」二级菜单工作。
- 弹幕数据来自用户自行部署的 danmu-api，脚本本身不附带弹幕服务。
- 为了读取飞牛影视的播放信息，脚本会在本地读取 fnOS 的 Trim-MC-token Cookie，并按其 Web 端 authx 规则生成请求签名；Token 只发往当前飞牛影视地址，不会发送到其他服务器。
- danmu-api 地址和 Token 由用户在设置窗口中填写，保存在油猴 GM 存储中，不写入脚本源码。
- @connect * 是因为飞牛的 NAS 地址由用户自定义（可能是任意局域网 IP / 域名），无法预先写死。
- 代码未压缩、未混淆，可直接审查。
```

## 注意事项

- `@connect *` 可能会被 Greasy Fork 审核关注；上面的说明已经解释原因。
- 脚本有 `@name:en`，Greasy Fork 要求同时提供非空的 `@description:en`；不要删除这一行，否则会报“@description:en 不能为空字符”。
- 不要把个人的 danmu-api Token、飞牛 Cookie 或 NAS 地址写进脚本/README。
- 脚本只支持 ScriptCat / Tampermonkey 等支持 `GM_*` 的管理器；需要用户自己部署 danmu-api。
- 当前脚本依赖飞牛播放器设置弹层的 DOM 结构；飞牛改版后可能需要更新选择器。
