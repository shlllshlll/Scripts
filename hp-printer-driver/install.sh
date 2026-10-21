#!/bin/bash
# =====================================================================
# install.sh —— 在装不上官方安装器的新 Mac 上还原 HP 驱动
#
#   sudo bash install.sh [备份目录]        安装（只装驱动层）
#   sudo bash install.sh --rollback [目录]  撤销安装
#   sudo bash install.sh --fix-ppd          重新补 PPD 的扫描仪关联
#         bash install.sh --dry-run [...]   只预览，不改动
#
#   核心约定：
#     * 只写 /Library，绝不碰 /Applications 和 /usr
#       （/Applications 与打印、扫描都无关，只是徒增几百 MB）
#     * 队列用 reference/ 里那条能用的队列 PPD，不用 lpinfo -m 去猜
#       HP 的驱动是 epcl2ppd 动态生成 PPD 的，标准 PPD 目录里没有这个型号
#     * 队列 URI 优先用 dnssd 且必须保留 ?bidi，否则耗材余量读不到
#     * 安装前把「新增」和「覆盖」都记进 install-state/，回滚照单执行
# =====================================================================
set -uo pipefail

DRY=0
MODE="install"
SRC=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --rollback) MODE="rollback" ;;
    --fix-ppd) MODE="fixppd" ;;
    -*) echo "未知参数: $a" >&2; exit 2 ;;
    *) SRC="$a" ;;
  esac
done

if [ "$DRY" -eq 0 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行： sudo bash \"$0\" $*" >&2; exit 1; }
fi

REAL_USER="${SUDO_USER:-root}"
HOME_DIR=$(eval echo "~$REAL_USER")

if [ "$MODE" != "fixppd" ]; then
  if [ -z "$SRC" ]; then
    for c in "$HOME_DIR/Desktop/HP-Driver-Backup" \
             "$HOME_DIR/Downloads/HP-Driver-Backup" \
             "$HOME_DIR/Documents/hp-rollback" \
             "/tmp/HP-Driver-Backup"; do
      { [ -d "$c/payload" ] || [ -d "$c/install-state" ]; } && { SRC="$c"; break; }
    done
  fi
  if [ "$MODE" = "rollback" ]; then
    [ -n "$SRC" ] && [ -d "$SRC/install-state" ] || {
      echo "回滚需要 <目录>/install-state（可用 --rollback <目录> 指定）" >&2; exit 1; }
  else
    [ -n "$SRC" ] && [ -d "$SRC/payload/Library/Printers/hp" ] || {
      echo "找不到备份（需要 <目录>/payload/Library/Printers/hp）" >&2; exit 1; }
  fi
  PAY="$SRC/payload"
  STATE="$SRC/install-state"
fi

SCANNER_MODULE="/Library/Image Capture/Devices/HP Scanner 3.app"
SCANNER_UUID="1077D9B5-1077-D9B5-1077-D9B51077D9B5"
QUEUE="HP_M176n_HP"

# =====================================================================
#  补 PPD 的扫描仪关联
#  macOS 靠这三行把「打印队列」和「扫描仪设备」绑在一起，缺了就没
#  「使用扫描仪」按钮。用系统设置重加打印机时它们会丢，用本函数补回。
# =====================================================================
fix_ppd() {
  local n=0 f
  [ -d "$SCANNER_MODULE" ] || { echo "扫描插件不在此机：$SCANNER_MODULE" >&2; return 1; }
  for f in /etc/cups/ppd/*.ppd; do
    [ -e "$f" ] || continue
    grep -qi 'HP Color LaserJet Pro MFP M176' "$f" || continue
    grep -q '^\*APScannerUUID' "$f" && continue
    printf '*APScannerUUID: "%s"\n*APScannerModulePath: "%s"\n' \
      "$SCANNER_UUID" "$SCANNER_MODULE" >> "$f"
    echo "  [+] 已补: $f"
    n=$((n+1))
  done
  if [ "$n" -eq 0 ]; then
    echo "  [=] 所有 HP 队列的 PPD 都已经带扫描仪关联，无需改动"
  else
    launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || killall -HUP cupsd 2>/dev/null
  fi
}

# =====================================================================
#  回滚
# =====================================================================
do_rollback() {
  echo "================================================================"
  echo " 回滚 HP 驱动安装"
  echo "================================================================"
  [ -d "$STATE" ] || { echo "没找到 $STATE" >&2; exit 1; }

  if grep -q '^queue_preexisted=1' "$STATE/meta.txt" 2>/dev/null; then
    echo "── 1. 队列 $QUEUE 安装前已存在，保留 ──"
  else
    echo "── 1. 删除队列 $QUEUE ──"
    lpadmin -x "$QUEUE" 2>/dev/null && echo "  [+] 已删除" || echo "  [-] 队列不存在"
    rm -f "/etc/cups/ppd/$QUEUE.ppd" 2>/dev/null
  fi

  if [ -f "$STATE/overwritten.tar.gz" ]; then
    echo "── 2. 还原被覆盖的原文件 ──"
    ( cd / && tar -xzf "$STATE/overwritten.tar.gz" ) \
      && echo "  [+] 已还原" || echo "  [!] 还原失败"
  else
    echo "── 2. 没有文件被覆盖 ──"
  fi

  if [ -s "$STATE/added.txt" ]; then
    echo "── 3. 删除新增路径（$(wc -l < "$STATE/added.txt" | tr -d ' ') 项）──"
    sort -r "$STATE/added.txt" | while IFS= read -r p; do
      [ -n "$p" ] && rm -rf "/$p" 2>/dev/null
    done
    echo "  [+] 完成"
  fi

  echo "── 4. 重启 CUPS ──"
  launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || killall -HUP cupsd 2>/dev/null
  sleep 2

  echo "── 5. 校验 ──"
  [ -e /Library/Printers/hp ] && echo "  [!] /Library/Printers/hp 仍在，可手工 rm -rf" \
    || echo "  ✓ /Library/Printers/hp 已清除"
  [ -e "$SCANNER_MODULE" ] && echo "  [!] 扫描插件仍在" || echo "  ✓ 扫描插件已清除"
  lpstat -p 2>/dev/null | sed 's/^/  /'
  echo "================================================================"
}

case "$MODE" in
  rollback) do_rollback; exit $? ;;
  fixppd)   fix_ppd; exit $? ;;
esac

echo "================================================================"
echo " 备份 : $SRC"
echo " 本机 : macOS $(sw_vers -productVersion) / $(uname -m)"
echo " 队列 : $QUEUE"
echo "================================================================"

# ------------------------------------------------------- 1. 前置校验
echo ""
echo "── 1. 校验备份完整性 ──"
need=(
  "Library/Printers/hp/cups/filters/raster2pclm.filter/Contents/MacOS/raster2pclm"
  "Library/Printers/hp/cups/filters/commandtohp.filter/Contents/MacOS/commandtohp"
  "Library/Printers/hp/filter/hpPreProcessing.filter/Contents/MacOS/hpPreProcessing"
  "Library/Printers/hp/PDEs/hpPostScriptPDE.plugin"
  "Library/Printers/hp/Utilities/HP Utility.app"
  "Library/Image Capture/Devices/HP Scanner 3.app"
)
bad=0
for f in "${need[@]}"; do
  if [ -e "$PAY/$f" ]; then echo "  ✓ ${f##*/}"; else echo "  ✗ 缺失: $f"; bad=1; fi
done
[ "$bad" -eq 0 ] || { echo "备份不完整，中止。" >&2; exit 1; }

# 队列 PPD：优先挑带扫描仪关联的那份（文件名里不是 _AirPrint_ / IPPf_）
PPD=""
for f in "$SRC/reference/"*.ppd; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in
    _AirPrint_*|IPPf_*) continue ;;
  esac
  PPD="$f"
done
[ -n "$PPD" ] || { echo "  ✗ reference/ 里没有队列 PPD" >&2; exit 1; }
echo "  ✓ PPD: $(basename "$PPD") ($(du -h "$PPD" | cut -f1))"

# ------------------------------------------- 2. 记录状态（回滚依据）
echo ""
echo "── 2. 记录安装前状态 ──"
if [ "$DRY" -eq 1 ]; then
  echo "  [dry] 将写入 $STATE/{added.txt,existed.txt,overwritten.tar.gz}"
else
  mkdir -p "$STATE"
  : > "$STATE/added.txt"
  : > "$STATE/existed.txt"
  while IFS= read -r -d '' f; do
    rel="${f#$PAY/}"
    if [ -e "/$rel" ] || [ -L "/$rel" ]; then
      echo "$rel" >> "$STATE/existed.txt"
    else
      echo "$rel" >> "$STATE/added.txt"
    fi
  done < <(find "$PAY/Library" -mindepth 1 -print0)
  [ -s "$STATE/existed.txt" ] && \
    ( cd / && tar -czf "$STATE/overwritten.tar.gz" -T "$STATE/existed.txt" 2>/dev/null )
  {
    echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "source=$SRC"
    echo "queue=$QUEUE"
    if lpstat -p "$QUEUE" >/dev/null 2>&1; then echo "queue_preexisted=1"; else echo "queue_preexisted=0"; fi
  } > "$STATE/meta.txt"
  echo "  新增 $(wc -l < "$STATE/added.txt" | tr -d ' ') 项 / 覆盖 $(wc -l < "$STATE/existed.txt" | tr -d ' ') 项"
fi

# ----------------------------------------------------------- 3. 还原
echo ""
echo "── 3. 还原文件（只写 /Library）──"
while IFS= read -r -d '' item; do
  n=$(basename "$item")
  if [ "$DRY" -eq 1 ]; then echo "  [dry]  /Library/$n"; continue; fi
  if ditto "$item" "/Library/$n"; then echo "  [+] /Library/$n"; else echo "  [!] 失败 /Library/$n"; fi
done < <(find "$PAY/Library" -mindepth 1 -maxdepth 1 -print0)

if [ -d "$PAY/Applications" ]; then
  echo "  [skip] payload/Applications 存在但被忽略（本脚本只装驱动层）"
fi
[ -d "$PAY/usr" ] && echo "  [skip] payload/usr（系统卷只读）"
[ "$DRY" -eq 1 ] && { echo ""; echo "dry-run 结束，未改动任何文件。"; exit 0; }

# --------------------------------------------------- 4. 权限与 quarantine
echo ""
echo "── 4. 清 quarantine、修 owner ──"
for d in "/Library/Printers/hp" "/Library/Printers/PPDs" "/Library/Printers/Icons" \
         "/Library/Image Capture" "/Library/ColorSync/Profiles"; do
  [ -e "$d" ] && xattr -dr com.apple.quarantine "$d" 2>/dev/null
done
chown -R root:wheel "/Library/Printers/hp" 2>/dev/null
chown -R root:wheel "/Library/Image Capture" 2>/dev/null
echo "  [√] 完成"

# ------------------------------------------------------------ 5. 重启 CUPS
echo ""
echo "── 5. 重启 CUPS ──"
launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || killall -HUP cupsd 2>/dev/null
sleep 2
echo "  [√] 完成"

# --------------------------------------------------------------- 6. 建队列
echo ""
echo "── 6. 建队列 ──"
URI=$(lpinfo -v 2>/dev/null | awk '/pdl-datastream/ && /M176/ {print $2; exit}')
if [ -z "$URI" ]; then
  URI="dnssd://HP%20Color%20LaserJet%20Pro%20MFP%20M176n%5BC0C702%5D._pdl-datastream._tcp.local./"
  echo "  [!] 未自动发现，使用备份里记录的 URI"
fi
case "$URI" in
  *\?*) : ;;
  *)    URI="$URI?bidi" ;;
esac
echo "  URI: $URI"

if lpstat -p "$QUEUE" >/dev/null 2>&1; then
  lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD" -o printer-is-shared=false \
    && echo "  [√] 已更新 $QUEUE"
else
  lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD" -o printer-is-shared=false \
    -o printer-error-policy=retry-job && echo "  [√] 已创建 $QUEUE"
fi
cupsenable "$QUEUE" 2>/dev/null
cupsaccept "$QUEUE" 2>/dev/null
fix_ppd >/dev/null 2>&1

# ------------------------------------------------------------ 7. 扫描发现
echo ""
echo "── 7. 让 ICA 重新枚举扫描插件 ──"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && [ -d "$SCANNER_MODULE" ] && "$LSREG" -f "$SCANNER_MODULE" 2>/dev/null
killall icdd 2>/dev/null
echo "  [√] icdd 已重启（launchd 会按需拉起）"

# --------------------------------------------------------------- 8. 自检
echo ""
echo "── 8. 自检 ──"
lpstat -p "$QUEUE" 2>&1 | head -3
echo ""
echo "  过滤链："
grep -E '^\*cupsFilter' "/etc/cups/ppd/$QUEUE.ppd" 2>/dev/null | sed 's/^/    /'
echo "  扫描仪关联："
grep -E '^\*APScanner' "/etc/cups/ppd/$QUEUE.ppd" 2>/dev/null | sed 's/^/    /' || echo "    (缺，用 --fix-ppd 补)"

echo ""
echo "================================================================"
echo " 下一步："
echo "   1) 打印    lp -d $QUEUE /etc/hosts"
echo "   2) 耗材    open \"/Library/Printers/hp/Utilities/HP Utility.app\""
echo "   3) 扫描    open -a \"Image Capture\""
echo "   4) 排查    tail -50 /var/log/cups/error_log"
echo ""
echo " 撤销安装：   sudo bash $0 --rollback \"$SRC\""
echo "================================================================"
