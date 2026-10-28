#!/usr/bin/env bash
set -euo pipefail

# media.sh - 通用媒体转换工具
#
# 子命令:
#   convert  图片格式转换与压缩（支持位图、EMF/WMF、SVG、gzip）
#   gif      视频转 GIF（支持指定帧率/宽度，或按目标大小自动调节）

# ---------- 全局依赖检查 ----------
require_cmds() {
  local miss=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || miss+=("$c")
  done
  if (( ${#miss[@]} > 0 )); then
    echo "错误: 缺少命令: ${miss[*]}" >&2
    exit 1
  fi
}
require_ffmpeg() {
  if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1 \
     || ! ffmpeg -version >/dev/null 2>&1 || ! ffprobe -version >/dev/null 2>&1; then
    echo "错误: ffmpeg 或 ffprobe 未安装，或当前无法正常运行。" >&2
    case "$(uname -s)" in
      Darwin) echo "macOS 安装: brew install ffmpeg；若已安装但报动态库缺失：brew reinstall ffmpeg x265" >&2 ;;
      Linux) echo "Linux 安装示例: sudo apt install ffmpeg（Debian/Ubuntu）或 sudo dnf install ffmpeg（Fedora）" >&2 ;;
      *) echo "请使用系统包管理器安装 ffmpeg。" >&2 ;;
    esac
    exit 1
  fi
}

die() { echo "错误: $*" >&2; exit 1; }

# 解析目标大小为字节数。支持 B/K/M（如 200K、1.5M）。返回 0 且写入全局 target_bytes。
parse_size() {
  local text=$1
  if [[ "$text" =~ ^([0-9]+([.][0-9]+)?)([Kk][Bb]?|[Mm][Bb]?|[Bb])?$ ]]; then
    local number=${BASH_REMATCH[1]}
    local unit=${BASH_REMATCH[3]:-B}
    local mult
    case "$(printf '%s' "$unit" | tr '[:lower:]' '[:upper:]')" in
      B)  mult=1 ;;
      K|KB) mult=1024 ;;
      M|MB) mult=$((1024 * 1024)) ;;
      *) return 1 ;;
    esac
    target_bytes=$(awk -v n="$number" -v m="$mult" 'BEGIN { printf "%d", n*m }')
    (( target_bytes > 0 )) || return 1
    return 0
  fi
  return 1
}

# ---------- convert 子命令 ----------
convert_usage() {
  cat <<'EOF'
用法:
  media.sh convert -i INPUT [-s SIZE] [-f FORMAT] [-o OUTPUT]

将图片转换格式并/或压缩到目标大小。
  -i, --input     输入文件或目录（目录时递归批量转换）
  -s, --size      目标大小（B/K/M，如 200K、1.5M）
                  -   仅转换格式，不做大小压缩
                  gzip  （仅 SVG 输出时）压缩为 .svgz
  -f, --format    输出格式: jpg/jpeg, avif, webp, heif/heic, svg（默认 jpg）
  -o, --output    输出文件（单文件）或输出目录（批量）

输入可为普通位图（jpg/jpeg/png/webp/heic/heif/avif）或 EMF/WMF 矢量图。
EMF/WMF 输出位图时先经 emf2svg-conv -> rsvg-convert 栅格化，再按目标大小压缩。

示例:
  media.sh convert -i photo.jpg -s 200K -f avif
  media.sh convert -i page.png -s 1M -f jpg -o compressed.jpg
  media.sh convert -i drawing.emf -s 200K -f webp
  media.sh convert -i drawing.emf -s - -f svg
  media.sh convert -i drawing.emf -s gzip -f svg
  media.sh convert -i ./images -s 200K -f avif -o ./converted
EOF
}

do_convert() {
  local input="" size="" format=jpg output=""
  local format_given=0
  while (( $# > 0 )); do
    case "$1" in
      -i|--input) input=$2; shift 2 ;;
      -s|--size) size=$2; shift 2 ;;
      -f|--format) format=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'); format_given=1; shift 2 ;;
      -o|--output) output=$2; shift 2 ;;
      -h|--help) convert_usage; exit 0 ;;
      *) echo "未知参数: $1" >&2; convert_usage; exit 2 ;;
    esac
  done
  [[ -n "$input" ]] || { echo "错误: 缺少 -i/--input" >&2; convert_usage; exit 2; }

  local mode=compress
  if [[ "$size" == "-" ]]; then
    mode=convert_only
  elif [[ "$size" == "gzip" ]]; then
    [[ "$format" == svg ]] || die "gzip 压缩仅用于 SVG 输出格式"
    mode=svg_gzip
  elif [[ -n "$size" ]]; then
    parse_size "$size" || die "目标大小格式无效: $size"
  else
    die "convert 需要 -s/--size（用 - 表示仅转换不压缩，或用 gzip 做 SVG gzip）"
  fi

  # batch_ext 用于批量模式下的输出扩展名（gzip 模式输出 .svgz）。
  case "$format" in
    jpg|jpeg) batch_ext=jpg ;;
    avif|webp|heic|heif) batch_ext=$format ;;
    svg) batch_ext=$([[ "$mode" == svg_gzip ]] && echo svgz || echo svg) ;;
    *) die "不支持的格式: ${format}（可用 jpg、avif、webp、heif、heic、svg）" ;;
  esac

  # 目录模式：递归批量，逐文件委派到单文件路径。
  if [[ -d "$input" ]]; then
    local output_dir=${output:-${input%/}_converted}
    mkdir -p "$output_dir"
    local input_dir output_abs count=0 failed=0
    input_dir=$(cd "$input" && pwd -P)
    output_abs=$(cd "$output_dir" && pwd -P)
    local relative filename stem destination_dir destination
    while IFS= read -r -d '' file; do
      relative=${file#"$input_dir"/}
      filename=$(basename "$relative")
      stem=${filename%.*}
      # 文件直接在输入根目录时 dirname 为 ".", 此时输出到 output_abs 根下。
      local rel_dir
      rel_dir=$(dirname "$relative")
      [[ "$rel_dir" == "." ]] && rel_dir=""
      destination_dir="$output_abs/$rel_dir"
      mkdir -p "$destination_dir"
      destination="$destination_dir/${stem}.${batch_ext}"
      echo "处理: $file"
      if "$0" convert -i "$file" -s "$size" -f "$format" -o "$destination"; then
        count=$((count + 1))
      else
        echo "失败: $file" >&2
        failed=$((failed + 1))
      fi
    done < <(find "$input_dir" -type d -path "$output_abs" -prune -o -type f \( \
      -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \
      -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.avif' \
      -o -iname '*.emf' -o -iname '*.wmf' \
    \) -print0)
    echo "批处理完成: 成功 $count 张，失败 $failed 张，输出目录: $output_dir"
    (( failed == 0 ))
    return
  fi

  convert_one "$input" "$mode" "$size" "$format" "$output" "$format_given"
}

# 单文件 convert 逻辑（含 EMF/WMF 与位图两套路径）。
convert_one() {
  local input=$1 mode=$2 size=$3 format=$4 output=$5 format_given=$6
  require_ffmpeg
  [[ -f "$input" ]] || die "输入文件不存在: $input"

  # 检测 EMF/WMF 输入（ffprobe 无法读取这类格式，按扩展名识别）。
  local input_lower=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
  local is_emf=0
  case "$input_lower" in
    *.emf|*.wmf) is_emf=1 ;;
  esac
  if (( is_emf )); then
    require_cmds emf2svg-conv
    if [[ "$mode" != svg_gzip && "$format" != svg ]]; then
      # 位图输出需要 rsvg-convert 栅格化。
      require_cmds rsvg-convert
    fi
  fi
  if [[ "$format" == svg && $is_emf -eq 0 ]]; then
    die "SVG 输出仅支持 EMF/WMF 矢量图输入（位图输入请用 jpg/avif/webp 等格式）"
  fi

  # 确定扩展名。gzip 模式（仅 SVG）输出 .svgz。
  local ext
  case "$format" in
    jpg|jpeg) ext=jpg ;;
    avif|webp|heic|heif) ext=$format ;;
    svg) if [[ "$mode" == svg_gzip ]]; then ext=svgz; else ext=svg; fi ;;
    *) die "不支持的格式: ${format}" ;;
  esac
  if [[ -z "$output" ]]; then
    local stem=${input%.*}
    output="${stem}_converted.${ext}"
  else
    output="${output%.*}.${ext}"
  fi

  tmpdir=$(mktemp -d)
  # 用全局 tmpdir（而非 local），确保函数返回后 EXIT trap 仍能清理它。
  trap 'if [[ -n "${tmpdir:-}" ]]; then rm -rf "$tmpdir"; fi' EXIT

  local quality_low quality_high
  local -a codec_args=()

  # ---------- EMF/WMF 输入 ----------
  if (( is_emf )); then
    if [[ "$format" == svg ]]; then
      local svg_out="$tmpdir/vector.svg"
      if ! emf2svg-conv -i "$input" -o "$svg_out" 2>"$tmpdir/emf.err"; then
        cat "$tmpdir/emf.err" >&2
        die "EMF 转 SVG 失败"
      fi
      if [[ "$mode" == svg_gzip ]]; then
        gzip -c "$svg_out" > "$output"
        printf '已生成: %s (gzip 压缩 SVG)\n大小: %s bytes\n' "$output" "$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output")"
      else
        cp -X "$svg_out" "$output" 2>/dev/null || cp "$svg_out" "$output"
        printf '已生成: %s (SVG)\n大小: %s bytes\n' "$output" "$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output")"
      fi
      return 0
    fi
    # 位图输出: EMF -> SVG -> PNG(rsvg) ，再走下方通用压缩路径。
    local svg_file="$tmpdir/emf.svg" png_file="$tmpdir/emf.png"
    if ! emf2svg-conv -i "$input" -o "$svg_file" 2>"$tmpdir/emf.err"; then
      cat "$tmpdir/emf.err" >&2
      die "EMF 转 SVG 失败"
    fi
    # 高分辨率栅格化给下游压缩留有搜索空间；实际输出宽度由 scale 滤镜控制。
    if ! rsvg-convert --keep-aspect-ratio -w 4096 "$svg_file" -o "$png_file" 2>"$tmpdir/rsvg.err"; then
      cat "$tmpdir/rsvg.err" >&2
      die "SVG 栅格化失败"
    fi
    input="$png_file"
  fi

  # ---------- 位图压缩路径 ----------
  case "$format" in
    jpg|jpeg)
      codec_args=(-c:v mjpeg -pix_fmt yuvj444p)
      quality_low=2; quality_high=31
      ;;
    avif)
      ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libsvtav1' || die "当前 ffmpeg 没有 libsvtav1 AV1 编码器"
      codec_args=(-c:v libsvtav1 -pix_fmt yuv420p -preset 6 -svtav1-params verbosity=0 -f avif)
      quality_low=0; quality_high=63
      ;;
    webp)
      codec_args=(-c:v libwebp -pix_fmt yuv420p)
      quality_low=0; quality_high=100
      ;;
    heif|heic)
      require_cmds heif-enc
      quality_low=0; quality_high=100
      ;;
    *) die "不支持的格式: ${format}" ;;
  esac

  local width height
  width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$input")
  height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input")
  [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]] || die "无法读取图片尺寸"

  local best="$tmpdir/best.$ext" best_bytes=0 best_width=0 best_quality=0

  encode() {
    local w=$1 q=$2 dst=$3
    local scale_filter="scale='min(${w},iw)':-2:flags=lanczos"
    local -a rate_args=()
    if [[ "$format" == heif || "$format" == heic ]]; then
      local png="$tmpdir/source.png"
      if ! ffmpeg -hide_banner -loglevel error -y -i "$input" -vf "$scale_filter" -frames:v 1 "$png"; then
        return 1
      fi
      if ! heif-enc --hevc -q "$q" -o "$dst" "$png" 2>"$tmpdir/heif.err"; then
        cat "$tmpdir/heif.err" >&2
        return 1
      fi
      return 0
    fi
    if [[ "$format" == avif ]]; then rate_args=(-crf "$q"); else rate_args=(-q:v "$q"); fi
    if ! ffmpeg -hide_banner -loglevel error -y -i "$input" -vf "$scale_filter" \
      "${codec_args[@]}" "${rate_args[@]}" "$dst" 2>"$tmpdir/ffmpeg.err"; then
      cat "$tmpdir/ffmpeg.err" >&2
      return 1
    fi
  }

  # 仅转换模式：最高质量编码一次，不做大小搜索。
  if [[ "$mode" == convert_only ]]; then
    local conv_q
    if [[ "$format" == webp ]]; then conv_q=$quality_high; else conv_q=$quality_low; fi
    if ! encode "$width" "$conv_q" "$best"; then die "仅转换模式编码失败"; fi
    cp -X "$best" "$output" 2>/dev/null || cp "$best" "$output"
    printf '已生成: %s (仅转换，不压缩)\n尺寸: %sx%s -> 宽度 %s\n大小: %s bytes\n质量参数: %s\n' \
      "$output" "$width" "$height" "$width" "$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output")" "$conv_q"
    return 0
  fi

  # 压缩模式：多宽度 × 二分搜索质量。
  # target_bytes 已由 do_convert 中 parse_size 解析为字节数（全局），此处直接使用。
  for candidate_width in "$width" 2400 2200 2000 1800 1600 1400 1200 1000 800 600; do
    (( candidate_width > width )) && continue
    local low=$quality_low high=$quality_high fit_quality=-1
    while (( low <= high )); do
      local mid=$(( (low + high) / 2 ))
      local candidate="$tmpdir/candidate.$ext"
      encode "$candidate_width" "$mid" "$candidate"
      local bytes
      bytes=$(stat -f%z "$candidate" 2>/dev/null || stat -c%s "$candidate")
      if (( bytes <= target_bytes )); then
        fit_quality=$mid
        if [[ "$format" == webp ]]; then low=$((mid + 1)); else high=$((mid - 1)); fi
      else
        if [[ "$format" == webp ]]; then high=$((mid - 1)); else low=$((mid + 1)); fi
      fi
    done
    (( fit_quality >= 0 )) || continue
    encode "$candidate_width" "$fit_quality" "$candidate"
    local b2
    b2=$(stat -f%z "$candidate" 2>/dev/null || stat -c%s "$candidate")
    if (( candidate_width > best_width )) || \
       (( candidate_width == best_width && b2 > best_bytes )); then
      cp -X "$candidate" "$best" 2>/dev/null || cp "$candidate" "$best"
      best_width=$candidate_width
      best_quality=$fit_quality
      best_bytes=$b2
    fi
  done
  (( best_width > 0 )) || die "无法在目标大小内生成文件，请增大目标大小"
  cp -X "$best" "$output" 2>/dev/null || cp "$best" "$output"
  printf '已生成: %s\n尺寸: %sx%s -> 宽度 %s\n大小: %s bytes (目标 <= %s bytes)\n质量参数: %s\n' \
    "$output" "$width" "$height" "$best_width" "$best_bytes" "$target_bytes" "$best_quality"
}

# ---------- gif 子命令 ----------
gif_usage() {
  cat <<'EOF'
用法:
  media.sh gif -i INPUT [-s SIZE] [--fps FPS] [--width WIDTH] [-o OUTPUT]

将视频转换为 GIF（palettegen/paletteuse 两遍法，色阶平滑）。
  -i, --input    输入视频文件或目录（目录时递归批量转换）
  -s, --size     目标大小，自动调节帧率与尺寸以逼近该大小
  -f, --fps      帧率（默认 10）
  -w, --width    输出宽度（默认 600；高度按原比例）
  -o, --output   输出文件（单文件）或输出目录（批量）

不指定 -s 时用给定 --fps/--width 直接转换一次。
指定 -s 时按"先保帧率、再保宽度、最后降帧率"的顺序自动寻找满足大小的组合。

示例:
  media.sh gif -i video.mp4
  media.sh gif -i video.mp4 -f 15 -w 800
  media.sh gif -i video.mp4 -s 2M
  media.sh gif -i ./videos -s 1M -o ./gifs
EOF
}

# 用给定 帧率/宽度 生成一次 gif。写入 $1 输出文件。
# 返回 0 成功，非 0 失败。产出大小用全局 gif_bytes 返回。
render_gif() {
  local in=$1 out=$2 fps=$3 width=$4
  local tdir
  tdir=$(mktemp -d)
  local pal="$tdir/pal.png"
  if ! ffmpeg -hide_banner -loglevel error -y -i "$in" -vf "fps=$fps,scale=$width:-1:flags=lanczos,palettegen" "$pal" 2>"$tdir/pal.err"; then
    cat "$tdir/pal.err" >&2
    rm -rf "$tdir"
    return 1
  fi
  if ! ffmpeg -hide_banner -loglevel error -y -i "$in" -i "$pal" \
    -filter_complex "fps=$fps,scale=$width:-1 [x];[x][1:v]paletteuse" "$out" 2>"$tdir/use.err"; then
    cat "$tdir/use.err" >&2
    rm -rf "$tdir"
    return 1
  fi
  rm -rf "$tdir"
  gif_bytes=$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out")
  return 0
}

do_gif() {
  local input="" size="" fps=10 width=600 output=""
  while (( $# > 0 )); do
    case "$1" in
      -i|--input) input=$2; shift 2 ;;
      -s|--size) size=$2; shift 2 ;;
      -f|--fps) fps=$2; shift 2 ;;
      -w|--width) width=$2; shift 2 ;;
      -o|--output) output=$2; shift 2 ;;
      -h|--help) gif_usage; exit 0 ;;
      *) echo "未知参数: $1" >&2; gif_usage; exit 2 ;;
    esac
  done
  [[ -n "$input" ]] || { echo "错误: 缺少 -i/--input" >&2; gif_usage; exit 2; }
  require_ffmpeg

  # 目录模式：递归批量转 gif。
  if [[ -d "$input" ]]; then
    local output_dir=${output:-${input%/}_gif}
    mkdir -p "$output_dir"
    local input_dir output_abs count=0
    input_dir=$(cd "$input" && pwd -P)
    output_abs=$(cd "$output_dir" && pwd -P)
    local relative stem destination
    while IFS= read -r -d '' file; do
      relative=${file#"$input_dir"/}
      stem=$(basename "${file%.*}")
      local rel_dir
      rel_dir=$(dirname "$relative")
      [[ "$rel_dir" == "." ]] && rel_dir=""
      mkdir -p "$output_abs/$rel_dir"
      destination="$output_abs/$rel_dir/${stem}.gif"
      echo "处理: $file"
      if "$0" gif -i "$file" -s "$size" -f "$fps" -w "$width" -o "$destination"; then
        count=$((count + 1))
      else
        echo "失败: $file" >&2
      fi
    done < <(find "$input_dir" -type d -path "$output_abs" -prune -o -type f \( \
      -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.webm' \
      -o -iname '*.avi' -o -iname '*.m4v' -o -iname '*.mpg' -o -iname '*.mpeg' \
    \) -print0)
    echo "GIF 批处理完成: 成功 $count 个，输出目录: $output_dir"
    return
  fi

  [[ -f "$input" ]] || die "输入文件不存在: $input"

  local gif_bytes=0
  local trial_dir
  trial_dir=$(mktemp -d)
  if [[ -n "$size" ]]; then
    # 自动大小调节：固定目标大小，自动寻找 (width, fps) 组合逼近目标。
    local target_bytes
    parse_size "$size" || die "目标大小格式无效: $size"

    local -a width_steps=( "$width" 800 640 480 360 240 160 120 96 64 )
    local -a fps_steps=( "$fps" 8 6 5 4 3 2 1 )
    local found=0 chosen_w=0 chosen_fps=0 chosen_file=""
    local f effw trial

    # 外层按帧率从高到低、内层按宽度从高到低；命中第一个满足大小即停止。
    # 优先保帧率（GIF 卡顿最伤观感），其次在该帧率下取尽量大的宽度。
    for f in "${fps_steps[@]}"; do
      (( f > fps )) && continue
      for effw in "${width_steps[@]}"; do
        (( effw > width )) && continue
        trial="$trial_dir/trial_${effw}_${f}.gif"
        if render_gif "$input" "$trial" "$f" "$effw"; then
          if (( gif_bytes <= target_bytes )); then
            chosen_w=$effw; chosen_fps=$f; chosen_file=$trial
            found=1
            break 2
          fi
        fi
      done
    done
    (( found )) || { rm -rf "$trial_dir"; die "无法在目标大小 $size 内生成 GIF（已尝试宽度 $width 至 64、帧率 $fps 至 1）"; }
    cp -X "$chosen_file" "$output" 2>/dev/null || cp "$chosen_file" "$output"
    rm -rf "$trial_dir"
    printf '已生成: %s\n尺寸: 宽度 %s, 帧率 %s\n大小: %s bytes (目标 <= %s bytes)\n' \
      "$output" "$chosen_w" "$chosen_fps" "$gif_bytes" "$target_bytes"
  else
    # 固定参数转换一次。
    if ! render_gif "$input" "$output" "$fps" "$width"; then
      rm -rf "$trial_dir"
      die "GIF 转换失败"
    fi
    rm -rf "$trial_dir"
    printf '已生成: %s\n宽度: %s, 帧率: %s\n大小: %s bytes\n' "$output" "$width" "$fps" "$gif_bytes"
  fi
}

# ---------- 主入口 ----------
main() {
  (( $# > 0 )) || { echo "缺少子命令" >&2; echo "可用: convert, gif" >&2; exit 2; }
  local sub=$1; shift
  case "$sub" in
    convert) do_convert "$@" ;;
    gif) do_gif "$@" ;;
    -h|--help|help) 
      echo "media.sh - 通用媒体转换工具"
      echo ""
      echo "用法: media.sh <子命令> [参数]"
      echo ""
      echo "子命令:"
      echo "  convert  图片格式转换与压缩"
      echo "  gif      视频转 GIF"
      echo ""
      echo "查看帮助: media.sh <子命令> --help"
      ;;
    *) echo "未知子命令: $sub" >&2; echo "可用: convert, gif" >&2; exit 2 ;;
  esac
}

main "$@"