# HP 打印机驱动迁移（macOS 跨版本）

新 macOS 上官方安装器装不上、但另一台机器上驱动跑得好好的——把驱动「搬」过来。

这套流程在 **HP Color LaserJet Pro MFP M176n** 上验证通过：macOS 27.0 →
macOS 27.0.1（均为 Apple Silicon），打印、耗材余量、内置「图像捕捉」扫描全部可用。

## 为什么官方安装器装不上

绝大多数情况不是驱动不兼容，而是安装包 `Distribution` 里的 `installation-check`
做了系统版本比对，直接把 27 拒了。所以有两条路：

| 方案 | 适用 | 做法 |
|---|---|---|
| A. 拆包 | 还留着官方 `.pkg` | `pkgutil --expand-full` 解开，把各子包 `Payload/` 手工铺到 `/` |
| B. 迁移 | 另一台机器上驱动是好的 | 本目录两个脚本 |

方案 A 更干净（拿到的是配套完整的一套），方案 B 的好处是不需要安装包。

## 脚本

```bash
# 在「驱动正常」的那台机器上（只读，不改配置）
sudo bash collect.sh
# → ~/Desktop/HP-Driver-Backup/  +  同名 zip

# 在「装不上」的新机器上（只写 /Library）
sudo bash install.sh ~/Desktop/HP-Driver-Backup
```

`install.sh` 的其他用法：

```bash
bash install.sh --dry-run <备份目录>    # 只预览
sudo bash install.sh --rollback [目录]  # 撤销安装
sudo bash install.sh --fix-ppd          # 修复 PPD 里的扫描仪关联
```

## 只装驱动层

脚本**只写 `/Library`**，不碰 `/Applications`，也不碰 `/usr`：

- 打印、耗材、扫描分别依赖 `/Library/Printers/hp`、`/Library/Image Capture/Devices`、
  `/Library/ColorSync/Profiles` 这几处
- `/Applications/HP.app`（HP Smart，几百 MB）与这三件事都没关系，装上纯属浪费
- HP Utility 本体在 `/Library/Printers/hp/Utilities/HP Utility.app`，
  直接 `open` 这个路径就能看碳粉，不需要 `/Applications` 里的快捷方式
- `/usr/libexec` 在 macOS 11+ 属于只读系统卷（SSV），写了也白写

## 四个坑（按踩到的顺序）

**1. PPD 不在标准 PPD 目录里。**
新版 HP 驱动用 `epcl2ppd` 动态生成 PPD，`/Library/Printers/PPDs/Contents/Resources/`
下只有传真和别家的 PPD。真正能用的那份是「源机器上那条配额队列」的
`/etc/cups/ppd/<队列名>.ppd`——所以 `collect.sh` 一定要把它抓进 `reference/`，
`install.sh` 用 `lpadmin -P` 直接装它，**不要**去 `lpinfo -m` 里找型号。

**2. 队列 URI 必须带 `?bidi`。**
耗材余量走的是双向通道，不是 SNMP（PPD 里 `*cupsSNMPSupplies: False`）。用
`socket://IP` 且不带 `?bidi` 建队列，打印正常但读不到碳粉。推荐
`dnssd://...._pdl-datastream._tcp.local./?bidi`。

**3. 系统设置里重加打印机会丢两行，扫描仪按钮就消失。**
macOS 靠 PPD 里这两行把「打印队列」和「扫描仪设备」绑起来：

```
*APScannerUUID: "1077D9B5-1077-D9B5-1077-D9B51077D9B5"
*APScannerModulePath: "/Library/Image Capture/Devices/HP Scanner 3.app"
```

系统设置添加打印机时驱动会重新生成 PPD，这两行不会带上。`install.sh --fix-ppd`
可以补回来。所以**能用就别删了重建**。

**4. 新拷进去的扫描插件，`icdd` 不会自动发现。**
插件靠 `CFBundleSignature = icae` 被 LaunchServices 枚举，`icdd` 在启动时建立设备
清单。装完必须重新 `lsregister -f` 再 `killall icdd`（脚本已做）；还不行就注销重登。

## 验证

```bash
lp -d <队列> /etc/hosts                  # 打印
lpstat -l -p <队列> | grep -i marker     # 耗材余量
open "/Library/Printers/hp/Utilities/HP Utility.app"
open -a "Image Capture"                  # 左侧应出现打印机
```

## 回滚

安装前会把「本次新增」和「将被覆盖」记进 `<备份目录>/install-state/`：

- `added.txt` —— 装之前不存在的路径，回滚时逐个删除
- `existed.txt` + `overwritten.tar.gz` —— 装之前就有、会被覆盖的，回滚时还原
- `meta.txt` —— 时间、来源、队列是否本来就存在

```bash
sudo bash install.sh --rollback <备份目录>
```

回滚只需要 `install-state/`（约 2 MB），那 900 MB 的 `payload/` 可以删掉。
本流程**不写安装收据**（`/private/var/db/receipts` 不变），所以不存在
「系统认为已安装」的残留，也不需要 `pkgutil --forget`。

## 排错

```bash
tail -50 /var/log/cups/error_log     # 打印失败，多半是 /Library/Printers/hp 的 owner 不对
sudo chown -R root:wheel /Library/Printers/hp

# 扫描发现类问题
dns-sd -B _scanner._tcp local        # HP 私有扫描服务是否在广播
log stream --predicate 'process == "icdd"'
```

`_uscan._tcp`（eSCL）与 `_scanner._tcp`（HP 私有，通常 8289 端口）是两件事：
老机型一般只广播后者，这时必须靠 HP 的 ICA 插件，系统自带的 AirScan 帮不上忙。

## 备注

- 备份体积主要来自 `/Library/Printers/hp/Utilities`（173 MB）、`Fax`（61 MB，
  无传真功能的机型可删）、`Frameworks`（32 MB）
- 驱动二进制是通用二进制（`x86_64 arm64`）。若源机是 Intel、目标机是 Apple
  Silicon，打印仍可用（CUPS 过滤器走 Rosetta 2），但扫描插件无法跨架构加载
- 本文的型号识别、队列命名请按自己机器改；`install.sh` 顶部的
  `SCANNER_MODULE` / `SCANNER_UUID` / `QUEUE` 三个变量是唯一需要动的常量
