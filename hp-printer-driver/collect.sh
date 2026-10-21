#!/bin/bash
# =====================================================================
# collect.sh —— 在「打印机驱动能正常工作」的 Mac 上收集 HP 驱动
#
#   sudo bash collect.sh [输出目录]
#
#   默认输出到 ~/Desktop/HP-Driver-Backup，并额外打一个同名 zip。
#
#   收集原则（都是踩过坑之后定的）：
#     * 全程用 ditto，保留 owner / 权限 / ACL / xattr / 符号链接
#     * 只收必要位置，混合目录按名字挑，避免把无关厂商的东西一起搬走
#     * 不收 /usr/libexec —— macOS 11+ 系统卷只读，拷过去也写不回
#     * 不收 /Applications —— 打印与扫描都不需要，只是徒增几百 MB
#     * 必须收 /etc/cups/ppd 里那条能用的队列 PPD，它是整个方案的关键
#
#   只读操作，不改动本机任何配置。
# =====================================================================
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 sudo 运行： sudo bash \"$0\"" >&2
  exit 1
fi

REAL_USER="${SUDO_USER:-root}"
HOME_DIR=$(eval echo "~$REAL_USER")
OUT="${1:-$HOME_DIR/Desktop/HP-Driver-Backup}"
PAYLOAD="$OUT/payload"
LOG="$OUT/report.txt"

rm -rf "$OUT"
mkdir -p "$PAYLOAD" "$OUT/reference"
: > "$LOG"

say()  { printf '%s\n' "$*" | tee -a "$LOG"; }
ok()   { printf '  \033[32m[+] \033[0m%s\n' "$*" | tee -a "$LOG"; }
warn() { printf '  \033[33m[!] \033[0m%s\n' "$*" | tee -a "$LOG"; }

say "================================================================"
say " 主机 : $(scutil --get ComputerName 2>/dev/null || hostname)"
say " 系统 : macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
say " 架构 : $(uname -m)"
say " 时间 : $(date '+%Y-%m-%d %H:%M:%S')"
say "================================================================"

# ---------------------------------------------------------------- 1. 收据
say ""
say "── 1. HP 相关 pkg 收据 ──"
# 注意：只匹配 ^com.hp.，否则 "SafariTechnologyPreview" 里的 hP 也会被算进来
PKGS=$(pkgutil --pkgs 2>/dev/null | grep -E '^com\.hp\.' || true)
if [ -z "$PKGS" ]; then
  warn "没找到 com.hp.* 收据，按已知路径兜底收集。"
else
  echo "$PKGS" | sed 's/^/  /' | tee -a "$LOG"
fi

# ------------------------------------------------- 2. 收据 BOM 里的文件清单
{
  echo ""
  echo "── 2. 收据 BOM 文件清单（核对漏拷用）──"
  for p in $PKGS; do
    echo ""
    echo "## $p"
    pkgutil --files "$p" 2>/dev/null | sed 's|^|/|'
  done
} >> "$LOG"

# ------------------------------------------------------------- 3. 拷贝文件
say ""
say "── 3. 收集驱动文件 ──"

copy_one() {                        # $1 = 绝对路径
  local src="$1" rel
  [ -e "$src" ] || return 0
  rel="${src#/}"
  mkdir -p "$PAYLOAD/$(dirname "$rel")"
  if ditto "$src" "$PAYLOAD/$rel" 2>/dev/null; then
    ok "$src"
  else
    warn "拷贝失败: $src"
  fi
}

# 3a. 驱动主体：整棵搬
for p in \
  "/Library/Printers/hp" \
  "/Library/Printers/PPDs" \
  "/Library/Printers/Icons" \
  "/Library/Application Support/HP" \
  "/Library/Application Support/Hewlett-Packard"
do
  copy_one "$p"
done

# 3b. 混合目录：只挑 HP 相关
pick() {                            # $1 = 目录  $2 = 深度
  local dir="$1" depth="${2:-3}"
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' f; do
    copy_one "$f"
  done < <(find "$dir" -maxdepth "$depth" \
             \( -iname '*hp*' -o -iname '*hewlett*' \) -print0 2>/dev/null)
}

for d in \
  "/Library/Image Capture" \
  "/Library/LaunchAgents" \
  "/Library/LaunchDaemons" \
  "/Library/PrivilegedHelperTools" \
  "/Library/ColorSync/Profiles"
do
  pick "$d" 3
done

# 3c. 明确不收，但记进报告，方便事后核对
{
  echo ""
  echo "── 3c. 有意未收集（仅供参考）──"
  echo "# /usr/libexec/cups —— 系统卷只读（SSV），安装时写不回去"
  find /usr/libexec/cups -maxdepth 2 -iname '*hp*' 2>/dev/null | sed 's/^/#   /'
  echo "# /Applications —— 与打印/扫描无关，只在报告里列出体积"
  for a in /Applications/HP*.app /Applications/HP /Applications/Hewlett-Packard; do
    [ -e "$a" ] && echo "#   $(du -sh "$a" 2>/dev/null | cut -f1)  $a"
  done
} >> "$LOG"

# ----------------------------------------------- 4. 参考用：队列与 PPD
say ""
say "── 4. 参考文件（关键：能用的队列 PPD）──"
for f in /private/etc/cups/ppd/*.ppd; do
  [ -e "$f" ] || continue
  cp "$f" "$OUT/reference/" 2>/dev/null && ok "reference/$(basename "$f")"
done
cp /private/etc/cups/printers.conf "$OUT/reference/printers.conf.txt" 2>/dev/null \
  && ok "reference/printers.conf.txt（含队列 URI，注意看有没有 ?bidi）"
if [ -z "$(ls -A "$OUT/reference" 2>/dev/null)" ]; then
  warn "没有队列 PPD。先在源机器上把打印机加好、确认能打印，再来收集。"
fi

# ------------------------------------------------------------ 5. 架构报告
say ""
say "── 5. 关键二进制架构（决定能否跨架构使用）──"
{
  echo ""
  echo "── 5. 关键二进制架构 ──"
  find /Library/Printers/hp -type f -perm -u+x 2>/dev/null | head -40 | while IFS= read -r f; do
    printf '  %-64s %s\n' "${f#/Library/Printers/}" "$(lipo -archs "$f" 2>/dev/null || echo '?')"
  done
  printf '  %-64s %s\n' "Image Capture/Devices/HP Scanner 3" \
    "$(lipo -archs "/Library/Image Capture/Devices/HP Scanner 3.app/Contents/MacOS/HP Scanner 3" 2>/dev/null || echo '?')"
} | tee -a "$LOG"

# ---------------------------------------------------------------- 6. 打包
say ""
ZIP="${OUT%/}.zip"
if ( cd "$(dirname "$OUT")" && rm -f "$ZIP" && ditto -c -k --sequesterRsrc --keepParent "$OUT" "$ZIP" ); then
  ok "压缩包: $ZIP ($(du -sh "$ZIP" | cut -f1))"
else
  warn "打包失败，直接传输整个目录也可以。"
fi

say ""
say "================================================================"
say " 完成。把这整个目录（或 zip）传到新机器，然后："
say "   sudo bash install.sh <备份目录>"
say "================================================================"
