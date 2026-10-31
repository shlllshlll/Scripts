#!/usr/bin/env bash
set -euo pipefail

# media.sh - 通用媒体转换工具
#
# 子命令:
#   convert  图片格式转换与压缩（支持位图、EMF/WMF、SVG、gzip）
#   gif      视频转 GIF（支持指定帧率/宽度，或按目标大小自动调节）
#   video    视频格式转换与压缩（多容器互转，可流复制或按码率/大小/CRF 压缩）
#   audio    音频提取与格式转换（视频/音频 -> m4a/mp3/flac/wav/opus 等）
#   info     查看媒体文件基本信息（编码/分辨率/帧率/码率/大小）

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

# 解析目标大小为字节数。与 macOS Finder 一致按 1:1000（K/M/G），
# 二进制单位用 KiB/MiB/GiB（1:1024）。例: 200K=200000，200KiB=204800。
parse_size() {
  local text=$1
  if [[ "$text" =~ ^([0-9]+([.][0-9]+)?)([A-Za-z]*)$ ]]; then
    local number=${BASH_REMATCH[1]}
    local unit
    unit=$(printf '%s' "${BASH_REMATCH[3]}" | tr '[:lower:]' '[:upper:]')
    local mult
    case "$unit" in
      ""|B)  mult=1 ;;
      K|KB)  mult=1000 ;;
      KI|KIB) mult=1024 ;;
      M|MB)  mult=1000000 ;;
      MI|MIB) mult=1048576 ;;
      G|GB)  mult=1000000000 ;;
      GI|GIB) mult=1073741824 ;;
      *) return 1 ;;
    esac
    target_bytes=$(awk -v n="$number" -v m="$mult" 'BEGIN { printf "%.0f", n*m }')
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
  -s, --size      目标大小（K/M/G 按 1:1000，如 200K、1.5M；KiB/MiB 按 1:1024）
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

# ---------- video 子命令 ----------
video_usage() {
  cat <<'EOF'
用法:
  media.sh video -i INPUT [-f FORMAT] [-s SIZE | -b BITRATE | -q VALUE] [选项] [-o OUTPUT]

视频格式转换与压缩（FFmpeg）。默认保持原分辨率、帧率与音轨；目标容器兼容时
直接流复制（无重编码、无画质损失），需要换编码器时按高画质重编码。
  -i, --input       输入视频文件或目录（目录时递归批量转换）
  -f, --format      目标格式: mp4, m4v, mov, mkv, webm, avi, wmv, flv, ts, mpg
                    （默认 mp4；给出 -o 时也可由输出扩展名推断）
  -o, --output      输出文件（单文件）或输出目录（批量）

压缩参数（-s / -b / -q 三选一；都不给即“不压缩”的高画质转换）:
  -s, --size        目标大小（K/M/G=1000 进制，如 700K、10M），按推算码率编码
                    -  显式表示仅转换格式、不做大小压缩
                    --no-adapt  禁用自动降分辨率/帧率（只按码率压）
  -b, --bitrate     视频码率（2M、1500k；裸数字按 kbps），单遍 ABR
  -q, --crf         画质值，越小越清晰：
                    libx264 0-51（默认 18）、libx265 0-51（默认 20）、
                    VP9/AV1/VVC 0-63（默认 32/30/32），wmv2/mpeg4 为 qscale 1-31（默认 2），
                    硬件编码（h264_hw/h265_hw）为 0-100，越大越清晰（默认 65）

其他:
  -r, --resolution  输出分辨率（1080p、720p、1280x720），默认保持原始
  --fps FPS         输出帧率，默认保持原始
  -a, --audio       音频: auto（默认，能复制则复制）| copy（强制复制）| 码率（如 192k）| none
  --abitrate RATE   音频码率（等价于 -a 192k）
  --acodec NAME     指定音频编码器：aac、mp3、opus、vorbis、flac、alac、ac3、eac3、mp2、wma、pcm
                    （默认按容器选择；容器不支持时报错）
  --ar RATE         音频采样率（如 44100、48000），默认保持原始
  --ac N            音频声道数（1 单声道、2 立体声、6 5.1），默认保持原始
  -I, --interactive 交互式选择 -s 方案：给出多组预计大小，可挑编号，也可用
                    r720 / f24 / b5000k / s150M 自己调整后确认
  -p, --preset      编码速度预设，仅 x264/x265 生效（默认 medium）
  --codec NAME      指定视频编码器，可写别名或 ffmpeg 编码器名（默认按容器选择）
                    别名: h264 h265(hevc) h266(vvc) av1 vp8 vp9 prores mpeg4 mpeg2 wmv2
                    硬件: h264_hw h265_hw；auto = 容器默认
                    容器装不下的组合（如 webm+h265）会立刻报错，不会等到封装阶段
  --copy            强制流复制（视频和音频都不重编码），容器不支持时报错
  -h, --help        显示帮助

说明:
  · 每次转换前先打印源文件摘要（大小/时长/编码/分辨率/帧率/码率/音频）。
  · 流复制仅在容器支持该编码、且未指定压缩/分辨率/帧率/编码器时自动启用。
  · 指定 --acodec/--abitrate/--ar/--ac 会强制重编码音频，容器需支持该音频编码。
  · 重编码统一输出 8bit yuv420p，保证 Windows 等平台播放器兼容。
  · 仅保留首条视频轨与首条音频轨，字幕和其余音轨不随转换保留。
  · wmv 使用 WMV8（wmv2）编码，Windows Media Player 可直接播放；
    FFmpeg 没有 WMV9（wmv3）编码器。
  · -s 会先按目标码率编码；对 wmv2 等码率控制较弱的编码器，会先用短片段
    试算，自动降低帧率/分辨率后再正式编码，尽量压进目标大小。
  · mp4/mov 里的 HEVC 会自动打 hvc1 标签，macOS 原生播放器可直接播放。

示例:
  media.sh video -i movie.mp4 -f wmv               # mp4 转 wmv（Win 播放，高画质）
  media.sh video -i movie.mp4 -f wmv -s 200M       # 同时压到 200M 左右
  media.sh video -i movie.mp4 -f wmv -q 4          # 画质稍降、体积更小
  media.sh video -i movie.mkv -f mp4 --copy        # 无损换容器（秒完成）
  media.sh video -i clip.mov -f mp4 -q 20 -r 1080p # 指定画质与分辨率
  media.sh video -i movie.mkv -f mp4 --acodec ac3 --ar 48000 --ac 6
  media.sh video -i movie.mp4 -f mkv --acodec opus --abitrate 96k
  media.sh video -i movie.mp4 -f mkv --codec h265 -q 22   # 用别名指定编码器
  media.sh video -i movie.mp4 -f webm --codec vp9 -q 32   # VP9 进 webm
  media.sh video -i ./videos -f wmv -o ./wmv       # 目录批量
EOF
  video_codec_help
}

# 码率解析：2M / 1500k / 裸数字（按 kbps，≥100000 视为 bps）。写入全局 bitrate_kbps。
parse_bitrate() {
  local text=$1
  if [[ "$text" =~ ^([0-9]+([.][0-9]+)?)([kKmM])?$ ]]; then
    local number=${BASH_REMATCH[1]}
    local unit=${BASH_REMATCH[3]:-}
    local kbps
    case "$unit" in
      M|m) kbps=$(awk -v n="$number" 'BEGIN { printf "%d", n * 1000 }') ;;
      K|k) kbps=$(awk -v n="$number" 'BEGIN { printf "%d", n }') ;;
      *)
        if [[ "$number" =~ ^[0-9]+$ ]] && (( number >= 100000 )); then
          kbps=$(( number / 1000 ))
        else
          kbps=$(awk -v n="$number" 'BEGIN { printf "%d", n }')
        fi
        ;;
    esac
    (( kbps > 0 )) || return 1
    bitrate_kbps=$kbps
    return 0
  fi
  return 1
}

# 与 macOS Finder 一致：1 kB = 1000 字节。
human_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1000000000) printf "%.2f GB", b / 1000000000;
    else if (b >= 1000000) printf "%.2f MB", b / 1000000;
    else if (b >= 1000) printf "%.1f kB", b / 1000;
    else printf "%d B", b;
  }'
}

# 生成可直接用于 -s 的尺寸写法（1:1000）。
size_arg() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1000000000) printf "%.2fG", b / 1000000000;
    else if (b >= 1000000) printf "%.2fM", b / 1000000;
    else if (b >= 1000) printf "%.0fK", b / 1000;
    else printf "%d", b;
  }'
}

human_bitrate() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1000000) printf "%.2f Mbps", b / 1000000;
    else if (b >= 1000) printf "%.0f kbps", b / 1000;
    else printf "%d bps", b;
  }'
}

human_duration() {
  awk -v s="$1" 'BEGIN {
    if (s < 0) s = 0;
    printf "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60;
  }'
}

fps_display() {
  awk -v r="$1" 'BEGIN {
    split(r, a, "/");
    if (a[2] > 0) printf "%.3g", a[1] / a[2];
    else if (r == "") printf "?";
    else printf "%s", r;
  }'
}

# ---------- 编码器探测（缓存本机 ffmpeg 的编码器表） ----------
# FF_ENCODERS 每行 "<编码器> <codec>"：取自 `ffmpeg -encoders` 里形如 "(codec h264)"
# 的标注；没有标注的（wmv2、mpeg4 等）编码器名即 codec 名。
ff_encoders_load() {
  [[ -n "${FF_ENCODERS+x}" ]] && return 0
  FF_ENCODERS=""
  command -v ffmpeg >/dev/null 2>&1 || return 1
  FF_ENCODERS=$(ffmpeg -hide_banner -encoders 2>/dev/null | awk '
    $2 ~ /^[a-z0-9_-]+$/ {
      codec = $2
      if (match($0, /\(codec [a-z0-9_-]+\)/)) {
        codec = substr($0, RSTART + 7, RLENGTH - 8)
      }
      print $2, codec
    }')
  [[ -n "$FF_ENCODERS" ]] || return 1
  return 0
}

have_encoder() {
  ff_encoders_load || return 1
  printf '%s\n' "$FF_ENCODERS" | awk -v e="$1" '$1 == e { found = 1 } END { exit !found }'
}

# 编码器 -> codec 名（h264/hevc/av1/...）。查不到时回退为编码器名。
video_encoder_codec() {
  local c=""
  if ff_encoders_load; then
    c=$(printf '%s\n' "$FF_ENCODERS" | awk -v e="$1" '$1 == e { print $2; exit }')
  fi
  [[ -n "$c" ]] || c=$1
  printf '%s\n' "$c"
}

# ---------- 视频编码器别名 ----------
# 别名 -> 候选编码器（逗号分隔，按优先级）；空串表示"用容器默认"。
video_codec_alias_candidates() {
  case "$1" in
    auto|default)                    printf '\n' ;;
    h264|avc|264|h.264)              printf 'libx264,h264_videotoolbox,libopenh264\n' ;;
    h264_hw|h264_vt|avc_hw)          printf 'h264_videotoolbox\n' ;;
    h265|hevc|265|h.265)             printf 'libx265,hevc_videotoolbox\n' ;;
    h265_hw|hevc_hw|h265_vt|hevc_vt) printf 'hevc_videotoolbox\n' ;;
    h266|vvc|266|h.266)              printf 'libvvenc\n' ;;
    av1|av01)                        printf 'libsvtav1,libaom-av1,librav1e\n' ;;
    vp8)                             printf 'libvpx\n' ;;
    vp9)                             printf 'libvpx-vp9\n' ;;
    prores|prores422)                printf 'prores_ks,prores_aw,prores\n' ;;
    mpeg4|divx|xvid)                 printf 'libxvid,mpeg4\n' ;;
    mpeg2|mpeg2video|dvd)            printf 'mpeg2video\n' ;;
    mpeg1|vcd)                       printf 'mpeg1video\n' ;;
    wmv|wmv2|wmv8)                   printf 'wmv2\n' ;;
    wmv1|wmv7)                       printf 'wmv1\n' ;;
    mjpeg|jpg|jpeg)                  printf 'mjpeg\n' ;;
    flv|flv1)                        printf 'flv\n' ;;
    *) return 1 ;;
  esac
}

# 解析 --codec 的取值：0=成功（结果在 video_encoder，空串=容器默认），
# 1=别名认识但本机无可用编码器，2=无法识别且不是编码器名。
video_codec_resolve() {
  local want=$1 cand c
  video_encoder=""
  video_codec_missing=""
  if cand=$(video_codec_alias_candidates "$want"); then
    [[ -z "$cand" ]] && return 0
    local IFS=,
    for c in $cand; do
      if have_encoder "$c"; then
        video_encoder=$c
        return 0
      fi
    done
    video_codec_missing=$cand
    return 1
  fi
  if have_encoder "$want"; then
    video_encoder=$want
    return 0
  fi
  return 2
}

# 容器可承载的视频 codec（用于重编码前的兼容性检查；流复制仍按 vc_copyv）。
video_container_encodable() {
  case "$1" in
    mp4|m4v) printf 'h264 hevc av1 mpeg4 mpeg2video mjpeg msmpeg4v3\n' ;;
    mov)     printf 'h264 hevc av1 mpeg4 mjpeg prores mpeg2video\n' ;;
    mkv)     printf '*\n' ;;
    webm)    printf 'vp8 vp9 av1\n' ;;
    avi)     printf 'mpeg4 mjpeg msmpeg4v3 msmpeg4v2 h264 hevc mpeg2video wmv2 ffv1\n' ;;
    wmv)     printf 'wmv1 wmv2 msmpeg4v3 mjpeg\n' ;;
    flv)     printf 'flv1 h264\n' ;;
    ts)      printf 'h264 hevc mpeg2video mpeg4\n' ;;
    mpg)     printf 'mpeg1video mpeg2video\n' ;;
    *)       printf '*\n' ;;
  esac
}

video_container_allows() { # $1=容器 $2=编码器
  local allow codec
  allow=$(video_container_encodable "$1")
  [[ "$allow" == "*" ]] && return 0
  codec=$(video_encoder_codec "$2")
  [[ " $allow " == *" $codec "* ]]
}

video_codec_label() { # codec -> 日常叫法
  case "$1" in
    hevc)       printf 'h265' ;;
    vvc)        printf 'h266' ;;
    mpeg2video) printf 'mpeg2' ;;
    mpeg1video) printf 'mpeg1' ;;
    *)          printf '%s' "$1" ;;
  esac
}

# 别名未命中时的补充提示（可能为空）。
video_codec_hint() {
  case "$1" in
    *libvvenc*) printf '；H.266/VVC 需自行编译 ffmpeg 并加 --enable-libvvenc（Homebrew 版不含）' ;;
    *videotoolbox*) printf '；当前系统没有可用的硬件编码器' ;;
    *) printf '；当前 ffmpeg 未包含该编码器，可换 --codec 或自行编译 ffmpeg' ;;
  esac
}

# 帮助里动态列出本机可用的编码别名。
video_codec_help() {
  printf '\n本机可用的视频编码（自动探测 ffmpeg）:\n'
  if ! ff_encoders_load; then
    printf '  未检测到 ffmpeg，无法探测；装好后自动列出。\n'
    return 0
  fi
  local alias cand c joined
  local IFS=,
  for alias in h264 h265 h266 av1 vp8 vp9 prores mpeg4 mpeg2 wmv2; do
    cand=$(video_codec_alias_candidates "$alias") || continue
    joined=""
    for c in $cand; do
      [[ -z "$c" ]] && continue
      if have_encoder "$c"; then joined+="${joined:+, }$c"; fi
    done
    if [[ -n "$joined" ]]; then
      printf '  %-6s → %s\n' "$alias" "$joined"
    else
      printf '  %-6s ✗ 不可用（需 %s）\n' "$alias" "${cand//,/ 或 }"
    fi
  done
  printf '  加 _hw 后缀用硬件编码（如 h265_hw）；auto = 容器默认。\n'
}

# 统计某类流的数量。TS 会为 program 与 stream 各输出一遍，去重后计数。
count_streams() { # $1 = v/a/s, $2 = 文件
  ffprobe -v error -select_streams "$1" -show_entries stream=index \
    -of default=nw=1:nk=1 "$2" 2>/dev/null | sort -n | uniq | wc -l | tr -d ' ' || true
}

# 读取单个字段。stream 为空时读 format 级字段。
# TS 等容器会同时输出 program 与 stream 段，只取第一行。
ffprobe_field() {
  local file=$1 stream=$2 entry=$3
  if [[ -n "$stream" ]]; then
    ffprobe -v error -select_streams "$stream" -show_entries "stream=$entry" \
      -of default=nw=1:nk=1 "$file" 2>/dev/null | head -1 || true
  else
    ffprobe -v error -show_entries "format=$entry" \
      -of default=nw=1:nk=1 "$file" 2>/dev/null | head -1 || true
  fi
}

# 音频编码器属性：ac_kind=lossy|lossless，ac_default_bit，ac_max_sr，ac_max_ch，ac_sr_set（空=不限）。
audio_codec_info() {
  ac_kind=lossy
  ac_default_bit=192k
  ac_max_sr=384000
  ac_max_ch=8
  ac_sr_set=""
  case "$1" in
    aac)
      ac_default_bit=192k; ac_max_sr=96000; ac_max_ch=8 ;;
    libmp3lame)
      ac_default_bit=192k; ac_max_sr=48000; ac_max_ch=2
      ac_sr_set="8000 11025 12000 16000 22050 24000 32000 44100 48000" ;;
    libopus)
      ac_default_bit=128k; ac_max_sr=48000; ac_max_ch=8
      ac_sr_set="8000 12000 16000 24000 48000" ;;
    libvorbis)
      ac_default_bit=160k; ac_max_sr=192000; ac_max_ch=8 ;;
    ac3)
      ac_default_bit=256k; ac_max_sr=48000; ac_max_ch=6
      ac_sr_set="32000 44100 48000" ;;
    eac3)
      ac_default_bit=256k; ac_max_sr=48000; ac_max_ch=8
      ac_sr_set="32000 44100 48000" ;;
    wmav1|wmav2)
      ac_default_bit=192k; ac_max_sr=48000; ac_max_ch=2
      ac_sr_set="8000 11025 12000 16000 22050 24000 32000 44100 48000" ;;
    mp2)
      ac_default_bit=192k; ac_max_sr=48000; ac_max_ch=2
      ac_sr_set="16000 22050 24000 32000 44100 48000" ;;
    flac|alac|pcm_*)
      ac_kind=lossless; ac_default_bit=""; ac_max_sr=384000; ac_max_ch=8 ;;
  esac
}

# 用户输入的音频编码器别名 -> FFmpeg 编码器名；未知返回 1。
audio_encoder_name() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    aac|m4a) printf 'aac\n' ;;
    mp3|libmp3lame|lame) printf 'libmp3lame\n' ;;
    opus|libopus) printf 'libopus\n' ;;
    vorbis|libvorbis|ogg) printf 'libvorbis\n' ;;
    flac) printf 'flac\n' ;;
    alac) printf 'alac\n' ;;
    wav|pcm|pcm_s16le) printf 'pcm_s16le\n' ;;
    pcm_s24le) printf 'pcm_s24le\n' ;;
    pcm_s32le) printf 'pcm_s32le\n' ;;
    ac3) printf 'ac3\n' ;;
    eac3) printf 'eac3\n' ;;
    mp2) printf 'mp2\n' ;;
    wma|wmav2) printf 'wmav2\n' ;;
    wmav1) printf 'wmav1\n' ;;
    copy) printf 'copy\n' ;;
    *) return 1 ;;
  esac
}

# 构建音频编码参数，结果写入全局 aa_args 及 aa_bit/aa_rate/aa_ch/aa_kind/aa_rate_changed/aa_ch_changed。
# $1 编码器  $2 码率(可空)  $3 显式采样率(可空)  $4 显式声道(可空)  $5 源采样率  $6 源声道
audio_build_encode() {
  local enc=$1 bit=$2 rate=$3 ch=$4 src_rate=$5 src_ch=$6
  aa_args=()
  aa_kind=lossy
  aa_bit=""
  aa_rate=""
  aa_ch=""
  aa_rate_changed=0
  aa_ch_changed=0

  audio_codec_info "$enc"
  aa_kind=$ac_kind
  aa_args=(-c:a "$enc")

  if [[ "$ac_kind" == lossy ]]; then
    if [[ -z "$bit" ]]; then bit=$ac_default_bit; fi
    aa_bit=$bit
    aa_args+=(-b:a "$bit")
  elif [[ -n "$bit" ]]; then
    echo "提示: $enc 为无损编码，忽略码率设置 ${bit}。" >&2
  fi

  # 采样率：显式指定时严格校验；否则按编码器上限/支持列表自动降。
  local want_rate=""
  if [[ -n "$rate" ]]; then
    if ! [[ "$rate" =~ ^[0-9]+$ ]]; then
      die "采样率无效: $rate"
    fi
    if [[ -n "$ac_sr_set" ]] && [[ " $ac_sr_set " != *" $rate "* ]]; then
      die "$enc 不支持采样率 ${rate}Hz（可用: ${ac_sr_set}）"
    fi
    if (( rate > ac_max_sr )); then
      die "$enc 最高支持 ${ac_max_sr}Hz 采样率"
    fi
    want_rate=$rate
  elif [[ -n "$src_rate" ]] && [[ "$src_rate" =~ ^[0-9]+$ ]]; then
    if [[ -n "$ac_sr_set" ]] && [[ " $ac_sr_set " != *" $src_rate "* ]]; then
      want_rate=48000
      (( ac_max_sr < 48000 )) && want_rate=$ac_max_sr
    elif (( src_rate > ac_max_sr )); then
      want_rate=$ac_max_sr
    fi
  fi
  if [[ -n "$want_rate" ]]; then
    aa_args+=(-ar "$want_rate")
    aa_rate=$want_rate
    aa_rate_changed=1
  fi

  # 声道：显式指定时严格校验；否则超出编码器上限才降。
  if [[ -n "$ch" ]]; then
    if ! [[ "$ch" =~ ^[1-9][0-9]*$ ]]; then
      die "声道数无效: $ch"
    fi
    if (( ch > ac_max_ch )); then
      die "$enc 最多支持 ${ac_max_ch} 声道"
    fi
    aa_args+=(-ac "$ch")
    aa_ch=$ch
    aa_ch_changed=1
  elif [[ -n "$src_ch" ]] && [[ "$src_ch" =~ ^[0-9]+$ ]] && (( src_ch > ac_max_ch )); then
    aa_args+=(-ac "$ac_max_ch")
    aa_ch=$ac_max_ch
    aa_ch_changed=1
  fi
}

# 容器属性通过 vc_* 全局变量返回。
video_container_info() {
  vc_name=$1
  case "$1" in
    mp4|m4v)
      vc_ext=$1
      vc_muxer=mp4
      vc_venc=libx264
      vc_aenc=aac
      vc_abit=192k
      vc_aencs=" aac libmp3lame ac3 eac3 alac "
      vc_copyv=" h264 hevc mpeg4 av1 "
      vc_copya=" aac mp3 ac3 eac3 alac "
      vc_faststart=1
      ;;
    mov)
      vc_ext=mov
      vc_muxer=mov
      vc_venc=libx264
      vc_aenc=aac
      vc_abit=192k
      vc_aencs=" aac libmp3lame ac3 eac3 alac pcm_s16le pcm_s24le "
      vc_copyv=" h264 hevc mpeg4 prores dnxhd av1 mjpeg "
      vc_copya=" aac mp3 ac3 eac3 alac pcm_s16le pcm_s24le "
      vc_faststart=1
      ;;
    mkv)
      vc_ext=mkv
      vc_muxer=matroska
      vc_venc=libx264
      vc_aenc=aac
      vc_abit=192k
      vc_aencs=" aac libmp3lame libopus libvorbis flac alac ac3 eac3 mp2 wmav2 pcm_s16le "
      vc_copyv="*"
      vc_copya="*"
      vc_faststart=0
      ;;
    webm)
      vc_ext=webm
      vc_muxer=webm
      vc_venc=libvpx-vp9
      vc_aenc=libopus
      vc_abit=128k
      vc_aencs=" libopus libvorbis "
      vc_copyv=" vp8 vp9 av1 "
      vc_copya=" opus vorbis "
      vc_faststart=0
      ;;
    avi)
      vc_ext=avi
      vc_muxer=avi
      vc_venc=mpeg4
      vc_aenc=libmp3lame
      vc_abit=192k
      vc_aencs=" libmp3lame ac3 pcm_s16le pcm_s24le "
      vc_copyv=" mpeg4 msmpeg4v3 mjpeg "
      vc_copya=" mp3 ac3 pcm_s16le "
      vc_faststart=0
      ;;
    wmv)
      vc_ext=wmv
      vc_muxer=asf
      vc_venc=wmv2
      vc_aenc=wmav2
      vc_abit=192k
      vc_aencs=" wmav2 wmav1 pcm_s16le "
      vc_copyv=" wmv1 wmv2 wmv3 vc1 msmpeg4v3 "
      vc_copya=" wmav1 wmav2 pcm_s16le "
      vc_faststart=0
      ;;
    flv)
      vc_ext=flv
      vc_muxer=flv
      vc_venc=libx264
      vc_aenc=aac
      vc_abit=128k
      vc_aencs=" aac libmp3lame "
      vc_copyv=" flv1 h264 "
      vc_copya=" aac mp3 "
      vc_faststart=0
      ;;
    ts)
      vc_ext=ts
      vc_muxer=mpegts
      vc_venc=libx264
      vc_aenc=aac
      vc_abit=192k
      vc_aencs=" aac ac3 eac3 libmp3lame mp2 "
      vc_copyv=" h264 hevc mpeg2video mpeg4 "
      vc_copya=" aac ac3 mp3 mp2 "
      vc_faststart=0
      ;;
    mpg)
      vc_ext=mpg
      vc_muxer=mpeg
      vc_venc=mpeg2video
      vc_aenc=mp2
      vc_abit=192k
      vc_aencs=" mp2 ac3 "
      vc_copyv=" mpeg1video mpeg2video "
      vc_copya=" mp2 mp1 ac3 "
      vc_faststart=0
      ;;
  esac
}

video_canonical_format() {
  case "$1" in
    mp4|m4v|mov|mkv|webm|avi|wmv|flv|ts|mpg) printf '%s\n' "$1" ;;
    asf) printf 'wmv\n' ;;
    m2ts|mts) printf 'ts\n' ;;
    mpeg|mpeg2|vob) printf 'mpg\n' ;;
    *) return 1 ;;
  esac
}

video_format_from_path() {
  local base=${1##*/}
  [[ "$base" == *.* ]] || return 1
  video_canonical_format "$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')"
}

# 容器允许该编码直接（流复制）封装时返回 0。
video_codec_allowed() {
  [[ "$1" == "*" ]] && return 0
  case " $1 " in *" $2 "*) return 0 ;; esac
  return 1
}

# 编码器画质参数族：crf（越小越好）、qscale（1-31，越小越好）、vt（0-100，越大越好）。
video_codec_family() {
  case "$1" in
    libx264|libx264rgb) vc_family=crf; vc_qdefault=18 ;;
    libx265) vc_family=crf; vc_qdefault=20 ;;
    libvpx|libvpx-vp9) vc_family=crf; vc_qdefault=32 ;;
    libsvtav1|libaom-av1|librav1e) vc_family=crf; vc_qdefault=30 ;;
    libvvenc) vc_family=crf; vc_qdefault=32 ;;
    h264_videotoolbox|hevc_videotoolbox|prores_videotoolbox) vc_family=vt; vc_qdefault=65 ;;
    prores_ks|prores_aw|prores) vc_family=qscale; vc_qdefault=6 ;;
    wmv2|mpeg4|mpeg2video|mpeg1video|libxvid|mjpeg|flv1|flv) vc_family=qscale; vc_qdefault=2 ;;
    *) vc_family=crf; vc_qdefault=18 ;;
  esac
}

video_supports_two_pass() {
  case "$1" in
    libx264|libx265|libvpx|libvpx-vp9|libsvtav1|libaom-av1|mpeg4|mpeg2video|libxvid) return 0 ;;
  esac
  return 1
}

# 选定编码器并做可用性回退，结果写入 video_encoder。
video_resolve_encoder() {
  local want=$1
  if have_encoder "$want"; then
    video_encoder=$want
    return 0
  fi
  case "$want" in
    libx264)
      if have_encoder libx265; then
        echo "提示: 当前 ffmpeg 缺少 libx264，改用 libx265。" >&2
        video_encoder=libx265
        return 0
      fi
      echo "提示: 当前 ffmpeg 缺少 libx264，改用 mpeg4（兼容性好，同码率画质较低）。" >&2
      video_encoder=mpeg4
      return 0
      ;;
    libvpx-vp9)
      die "当前 ffmpeg 缺少 libvpx-vp9 编码器，无法生成 webm；请安装完整版 ffmpeg 或改用 mp4/mkv。" ;;
    libopus)
      die "当前 ffmpeg 缺少 libopus 编码器，无法生成 webm 音频。" ;;
    *)
      die "当前 ffmpeg 缺少编码器: $want" ;;
  esac
}

do_video() {
  local input="" format="" output=""
  vopt_size=""; vopt_size_active=0; vopt_target_bytes=0; vopt_size_given=0
  vopt_bitrate=""; vopt_bitrate_kbps=0
  vopt_crf=""; vopt_resolution=""; vopt_fps=""
  vopt_audio_mode=auto; vopt_audio_value=""; vopt_abitrate=""; vopt_abitrate_opt=""
  vopt_acodec=""; vopt_arate=""; vopt_achannels=""
  vopt_preset=medium; vopt_codec=""; vopt_force_copy=0; vopt_no_adapt=0; vopt_interactive=0

  while (( $# > 0 )); do
    case "$1" in
      -i|--input) input=$2; shift 2 ;;
      -f|--format) format=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'); shift 2 ;;
      -o|--output) output=$2; shift 2 ;;
      -s|--size) vopt_size=$2; vopt_size_given=1; shift 2 ;;
      -b|--bitrate) vopt_bitrate=$2; shift 2 ;;
      -q|--crf) vopt_crf=$2; shift 2 ;;
      -r|--resolution) vopt_resolution=$2; shift 2 ;;
      --fps) vopt_fps=$2; shift 2 ;;
      -a|--audio) vopt_audio_value=$2; shift 2 ;;
      --abitrate|--audio-bitrate) vopt_abitrate_opt=$2; shift 2 ;;
      --acodec|--audio-codec) vopt_acodec=$2; shift 2 ;;
      --ar|--audio-rate|--sample-rate) vopt_arate=$2; shift 2 ;;
      --ac|--audio-channels|--channels) vopt_achannels=$2; shift 2 ;;
      -p|--preset) vopt_preset=$2; shift 2 ;;
      --codec) vopt_codec=$2; shift 2 ;;
      --copy) vopt_force_copy=1; shift ;;
      --no-adapt) vopt_no_adapt=1; shift ;;
      -I|--interactive) vopt_interactive=1; shift ;;
      -h|--help) video_usage; exit 0 ;;
      *) echo "未知参数: $1" >&2; video_usage; exit 2 ;;
    esac
  done
  [[ -n "$input" ]] || { echo "错误: 缺少 -i/--input" >&2; video_usage; exit 2; }

  # ---------- 目标格式 ----------
  if [[ -z "$format" && -n "$output" && ! -d "$output" ]]; then
    format=$(video_format_from_path "$output" || true)
  fi
  [[ -n "$format" ]] || format=mp4
  local canonical
  if ! canonical=$(video_canonical_format "$format"); then
    die "不支持的输出格式: ${format}（可用: mp4、m4v、mov、mkv、webm、avi、wmv、flv、ts、mpg）"
  fi
  format=$canonical
  video_container_info "$format"

  # ---------- 参数校验 ----------
  if [[ "$vopt_size" == "-" ]]; then
    vopt_size=""
  elif [[ -n "$vopt_size" ]]; then
    parse_size "$vopt_size" || die "目标大小格式无效: ${vopt_size}（示例: 700K、10M）"
    vopt_size_active=1
    vopt_target_bytes=$target_bytes
  fi

  local pick=0
  (( vopt_size_active )) && pick=$(( pick + 1 ))
  [[ -n "$vopt_bitrate" ]] && pick=$(( pick + 1 ))
  [[ -n "$vopt_crf" ]] && pick=$(( pick + 1 ))
  (( pick <= 1 )) || die "-s/--size、-b/--bitrate、-q/--crf 只能三选一"

  if [[ -n "$vopt_bitrate" ]]; then
    parse_bitrate "$vopt_bitrate" || die "码率格式无效: ${vopt_bitrate}（示例: 2M、1500k）"
    vopt_bitrate_kbps=$bitrate_kbps
  fi

  if [[ -n "$vopt_crf" ]]; then
    [[ "$vopt_crf" =~ ^[0-9]+$ ]] || die "-q/--crf 需要整数"
  fi

  if [[ -n "$vopt_resolution" ]]; then
    if ! [[ "$vopt_resolution" =~ ^[0-9]+[pP]$ ]] \
       && ! [[ "$vopt_resolution" =~ ^[0-9]+[xX][0-9]+$ ]] \
       && ! [[ "$vopt_resolution" =~ ^[0-9]+$ ]]; then
      die "分辨率格式无效: ${vopt_resolution}（示例: 1080p、720p、1280x720）"
    fi
  fi

  if [[ -n "$vopt_fps" ]]; then
    [[ "$vopt_fps" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "帧率格式无效: $vopt_fps"
  fi

  # ---------- 音频参数 ----------
  case "$vopt_audio_value" in
    "")
      vopt_audio_mode=auto ;;
    auto|copy|none)
      vopt_audio_mode=$vopt_audio_value ;;
    *)
      parse_bitrate "$vopt_audio_value" || die "音频参数无效: ${vopt_audio_value}（auto/copy/none 或码率如 192k）"
      vopt_audio_mode=encode
      vopt_abitrate=$vopt_audio_value
      ;;
  esac

  if [[ -n "$vopt_abitrate_opt" ]]; then
    if [[ -n "$vopt_abitrate" ]]; then
      die "-a 已指定音频码率，不能再与 --abitrate 同时使用"
    fi
    vopt_abitrate=$vopt_abitrate_opt
  fi

  if [[ -n "$vopt_abitrate" ]]; then
    parse_bitrate "$vopt_abitrate" || die "音频码率无效: ${vopt_abitrate}（示例: 192k、320k）"
  fi

  if [[ -n "$vopt_acodec" ]]; then
    local mapped
    if ! mapped=$(audio_encoder_name "$vopt_acodec"); then
      die "未知音频编码器: ${vopt_acodec}（可用: aac、mp3、opus、vorbis、flac、alac、ac3、eac3、mp2、wma、pcm）"
    fi
    vopt_acodec=$mapped
    if [[ "$vopt_acodec" == copy ]]; then
      vopt_acodec=""
      vopt_audio_mode=copy
    fi
  fi

  if [[ -n "$vopt_arate" ]]; then
    [[ "$vopt_arate" =~ ^[0-9]+$ ]] || die "音频采样率无效: $vopt_arate"
  fi
  if [[ -n "$vopt_achannels" ]]; then
    [[ "$vopt_achannels" =~ ^[1-9][0-9]*$ ]] || die "音频声道数无效: $vopt_achannels"
  fi

  if [[ "$vopt_audio_mode" == none ]]; then
    if [[ -n "$vopt_acodec" || -n "$vopt_arate" || -n "$vopt_achannels" || -n "$vopt_abitrate" ]]; then
      die "-a none 不能与其他音频参数同时使用"
    fi
  elif [[ "$vopt_audio_mode" == copy ]]; then
    if [[ -n "$vopt_acodec" || -n "$vopt_arate" || -n "$vopt_achannels" || -n "$vopt_abitrate" ]]; then
      die "音频流复制时不能设置编码器/码率/采样率/声道"
    fi
  elif [[ -n "$vopt_acodec" || -n "$vopt_arate" || -n "$vopt_achannels" || -n "$vopt_abitrate" ]]; then
    vopt_audio_mode=encode
  fi

  [[ -n "$vopt_preset" ]] || die "-p/--preset 不能为空"

  if [[ -n "$vopt_codec" ]]; then
    vopt_codec=$(printf '%s' "$vopt_codec" | tr '[:upper:]' '[:lower:]')
  fi
  if [[ "$vopt_codec" == copy ]]; then
    vopt_codec=""
    vopt_force_copy=1
  fi
  if (( vopt_force_copy )) && [[ -n "$vopt_codec" ]]; then
    die "--copy 表示不重编码，不能与 --codec 同时使用（去掉其中一个）"
  fi
  if [[ -n "$vopt_codec" ]]; then
    local codec_rc=0 codec_allow codec_name allow_item allow_list
    video_codec_resolve "$vopt_codec" || codec_rc=$?
    if (( codec_rc == 0 )); then
      vopt_codec=$video_encoder
    elif (( codec_rc == 1 )); then
      die "本机 ffmpeg 没有 ${vopt_codec} 需要的编码器（已尝试: ${video_codec_missing//,/、}）$(video_codec_hint "$video_codec_missing")"
    else
      die "无法识别的视频编码器: ${vopt_codec}（可用别名见 media.sh video --help，或直接写 ffmpeg 编码器名，如 libx264）"
    fi
    if [[ -n "$vopt_codec" ]] && ! video_container_allows "$format" "$vopt_codec"; then
      codec_name=$(video_codec_label "$(video_encoder_codec "$vopt_codec")")
      codec_allow=$(video_container_encodable "$format")
      allow_list=""
      if [[ "$codec_allow" != "*" ]]; then
        for allow_item in $codec_allow; do
          allow_list+="${allow_list:+, }$(video_codec_label "$allow_item")"
        done
      fi
      die "$format 容器装不下 ${codec_name}（${vopt_codec}）；该容器支持: ${allow_list}。可改用 -f mkv，或换 --codec"
    fi
  fi

  if (( vopt_force_copy )); then
    if [[ -n "$vopt_crf" || -n "$vopt_bitrate" || -n "$vopt_resolution" || -n "$vopt_fps" ]]; then
      die "--copy 不能与 -q/-b/-r/--fps 同时使用"
    fi
    (( vopt_size_active )) && die "--copy 不能与 -s 同时使用（流复制不会重新压缩）"
  fi
  # --copy 意味着音视频都不重编码；未显式指定音频参数时按 copy 处理。
  if (( vopt_force_copy )); then
    if [[ "$vopt_audio_mode" == auto ]]; then
      vopt_audio_mode=copy
    fi
    if [[ "$vopt_audio_mode" == encode ]]; then
      die "--copy 不能与音频重编码参数（-a 码率/--abitrate/--acodec/--ar/--ac）同时使用"
    fi
  fi

  if (( vopt_interactive )); then
    if [[ -d "$input" ]]; then die "--interactive 不支持目录批量"; fi
    if [[ -n "$vopt_bitrate" || -n "$vopt_crf" || -n "$vopt_resolution" || -n "$vopt_fps" ]]; then
      die "--interactive 不能与 -b/-q/-r/--fps 同时使用（进入交互后可直接调整）"
    fi
    if (( vopt_force_copy )); then die "--interactive 与 --copy 冲突"; fi
    if (( vopt_no_adapt )); then die "--interactive 与 --no-adapt 冲突"; fi
    [[ -f "$input" ]] || die "输入文件不存在: $input"
  fi

  # ---------- 目录批量 ----------
  if [[ -d "$input" ]]; then
    local output_dir=${output:-${input%/}_video}
    mkdir -p "$output_dir"
    local input_dir output_abs count=0 failed=0
    input_dir=$(cd "$input" && pwd -P)
    output_abs=$(cd "$output_dir" && pwd -P)
    local -a child_opts=(-p "$vopt_preset")
    if [[ -n "$vopt_abitrate" ]]; then
      child_opts+=(-a "$vopt_abitrate")
    elif [[ "$vopt_audio_mode" != encode ]]; then
      child_opts+=(-a "$vopt_audio_mode")
    fi
    if [[ -n "$vopt_acodec" ]]; then child_opts+=(--acodec "$vopt_acodec"); fi
    if [[ -n "$vopt_arate" ]]; then child_opts+=(--ar "$vopt_arate"); fi
    if [[ -n "$vopt_achannels" ]]; then child_opts+=(--ac "$vopt_achannels"); fi
    if (( vopt_size_active )); then child_opts+=(-s "$vopt_size"); fi
    if [[ -n "$vopt_bitrate" ]]; then child_opts+=(-b "$vopt_bitrate"); fi
    if [[ -n "$vopt_crf" ]]; then child_opts+=(-q "$vopt_crf"); fi
    if [[ -n "$vopt_resolution" ]]; then child_opts+=(-r "$vopt_resolution"); fi
    if [[ -n "$vopt_fps" ]]; then child_opts+=(--fps "$vopt_fps"); fi
    if [[ -n "$vopt_codec" ]]; then child_opts+=(--codec "$vopt_codec"); fi
    if (( vopt_force_copy )); then child_opts+=(--copy); fi
    if (( vopt_no_adapt )); then child_opts+=(--no-adapt); fi

    local -a find_cmd=(find "$input_dir")
    if [[ "$output_abs" != "$input_dir" ]]; then
      find_cmd+=(-type d -path "$output_abs" -prune -o)
    fi
    find_cmd+=(-type f \( \
      -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mov' -o -iname '*.mkv' \
      -o -iname '*.webm' -o -iname '*.avi' -o -iname '*.wmv' -o -iname '*.asf' \
      -o -iname '*.flv' -o -iname '*.ts' -o -iname '*.m2ts' -o -iname '*.mpg' \
      -o -iname '*.mpeg' -o -iname '*.3gp' -o -iname '*.vob' \
    \) -print0)

    local relative stem rel_dir destination
    while IFS= read -r -d '' file; do
      relative=${file#"$input_dir"/}
      stem=$(basename "${file%.*}")
      rel_dir=$(dirname "$relative")
      [[ "$rel_dir" == "." ]] && rel_dir=""
      mkdir -p "$output_abs/$rel_dir"
      if [[ -z "$rel_dir" ]]; then
        destination="$output_abs/${stem}.${vc_ext}"
      else
        destination="$output_abs/$rel_dir/${stem}.${vc_ext}"
      fi
      if [[ "$destination" == "$file" ]]; then
        destination="${destination%.*}_converted.${vc_ext}"
      fi
      echo "处理: $file"
      if "$0" video -i "$file" -f "$format" -o "$destination" "${child_opts[@]}"; then
        count=$(( count + 1 ))
      else
        echo "失败: $file" >&2
        failed=$(( failed + 1 ))
      fi
    done < <("${find_cmd[@]}")
    echo "视频批处理完成: 成功 $count 个，失败 $failed 个，输出目录: $output_dir"
    (( failed == 0 ))
    return
  fi

  [[ -f "$input" ]] || die "输入文件不存在: $input"

  # ---------- 输出路径 ----------
  local ext=$vc_ext
  local in_dir in_stem
  in_dir=$(dirname "$input")
  [[ "$in_dir" == "." ]] && in_dir=""
  in_stem=${input##*/}
  in_stem=${in_stem%.*}

  if [[ -z "$output" ]]; then
    if [[ -z "$in_dir" ]]; then
      output="${in_stem}_${format}.${ext}"
    else
      output="$in_dir/${in_stem}_${format}.${ext}"
    fi
  elif [[ "$output" == */ || -d "$output" ]]; then
    # -o 指向目录（或以 / 结尾）：沿用默认文件名放进该目录。
    local dir_target=${output%/}
    if [[ -z "$dir_target" ]]; then
      output="${in_stem}_${format}.${ext}"
    else
      output="$dir_target/${in_stem}_${format}.${ext}"
    fi
  else
    local out_dir="" out_name=$output
    if [[ "$output" == */* ]]; then
      out_dir=${output%/*}
      out_name=${output##*/}
    fi
    if [[ "$out_name" == *.* ]]; then
      out_name="${out_name%.*}.${ext}"
    else
      out_name="${out_name}.${ext}"
    fi
    if [[ -z "$out_dir" ]]; then
      output=$out_name
    else
      output="$out_dir/$out_name"
    fi
  fi
  local out_parent
  out_parent=$(dirname "$output")
  [[ -d "$out_parent" ]] || mkdir -p "$out_parent"

  video_one "$input" "$output"
}

# ---------- 采样试算与交互选择（video -s 使用） ----------
# 以下函数依赖 video_one 作用域中的变量（bash 动态作用域），调用前需就绪：
# input/enc/vopt_preset/vc_muxer/sample_len/start_s/sample_path/src_h_num/
# src_fps/src_duration/audio_kbps/audio_est/video_target/vopt_target_bytes 等。

# 用指定档位编码短片段，估算整片字节数并输出。$1 高度(0=原始) $2 帧率(空=原始) $3 视频码率kbps
video_sample_estimate() {
  local t_h=$1 t_f=$2 b=$3
  local -a sargs=(ffmpeg -hide_banner -nostdin -loglevel error -y)
  if [[ "$start_s" != "0" ]]; then sargs+=(-ss "$start_s"); fi
  sargs+=(-i "$input" -t "$sample_len" -map 0:v:0 -an)
  if (( t_h > 0 && t_h < src_h_num )); then
    sargs+=(-vf "scale=-2:${t_h}:flags=lanczos")
  fi
  if [[ -n "$t_f" ]]; then sargs+=(-r "$t_f"); fi
  sargs+=(-c:v "$enc")
  case "$enc" in
    libx264|libx265) sargs+=(-preset "$vopt_preset") ;;
  esac
  case "$enc" in
    libx265) sargs+=(-x265-params log-level=error) ;;
    libvpx|libvpx-vp9) sargs+=(-row-mt 1 -deadline good -cpu-used 2) ;;
  esac
  case "$enc" in
    wmv2|mpeg4|mpeg2video|mjpeg|libxvid|libvpx|libvpx-vp9|libx264|libx265|libsvtav1|libaom-av1|libvvenc|h264_videotoolbox|hevc_videotoolbox|flv)
      sargs+=(-pix_fmt yuv420p) ;;
  esac
  sargs+=(-b:v "${b}k" -maxrate "$(( b * 12 / 10 ))k" -bufsize "$(( b * 2 ))k")
  sargs+=(-f "$vc_muxer" "$sample_path")
  if ! "${sargs[@]}" >/dev/null 2>&1; then
    return 1
  fi
  local sbytes
  sbytes=$(stat -f%z "$sample_path" 2>/dev/null || stat -c%s "$sample_path")
  awk -v sb="$sbytes" -v sl="$sample_len" -v d="$src_duration" -v ak="$audio_kbps" \
    'BEGIN { v = sb / sl * d; a = ak * 1000 / 8 * d; printf "%.0f", (v + a) * 1.05 }'
}

# 在单个档位下校准码率。结果写入调用方作用域的 cal_b / cal_est / cal_ok / cal_trials。
# $1 高度 $2 帧率 $3 初始码率 $4 码率下限 $5 最大轮数(默认3)
video_calibrate_profile() {
  local t_h=$1 t_f=$2 b=$3 floor=$4 max_iter=${5:-3}
  local iter=0 est next_b est_video
  cal_ok=0
  cal_est=0
  cal_b=$b
  cal_trials=0
  while (( iter < max_iter )); do
    iter=$(( iter + 1 ))
    est=$(video_sample_estimate "$t_h" "$t_f" "$b") || break
    cal_trials=$(( cal_trials + 1 ))
    cal_est=$est
    cal_b=$b
    if (( est <= vopt_target_bytes )); then
      cal_ok=1
      return 0
    fi
    est_video=$(( est - audio_est ))
    (( est_video < 1 )) && est_video=1
    next_b=$(awk -v b="$b" -v vt="$video_target" -v ev="$est_video" \
      'BEGIN { n = b * vt / ev * 0.95; if (n < 64) n = 64; printf "%d", n }')
    if (( next_b >= b )); then break; fi
    b=$next_b
    if (( b < floor )); then break; fi
  done
  return 0
}

# 解析 "高度|帧率|码率|预计|符合" 菜单项，写入调用方作用域的 vi_*。
video_load_menu_item() {
  local it=$1
  vi_h=${it%%|*}; it=${it#*|}
  vi_f=${it%%|*}; it=${it#*|}
  vi_b=${it%%|*}; it=${it#*|}
  vi_est=${it%%|*}; vi_ok=${it#*|}
}

# 确认提示。返回 0=确认，1=返回调整，2=取消。
video_confirm_plan() {
  local ans
  printf '开始转换？[Y/n/q] '
  if ! IFS= read -r ans; then
    echo
    return 2
  fi
  case "$ans" in
    ""|y|Y|yes|YES) return 0 ;;
    q|Q) return 2 ;;
    *) return 1 ;;
  esac
}

# 交互式选择档位。结果写入调用方作用域的 isel_h / isel_f / isel_b / isel_est。
# 成功返回 0；试算失败返回 1（由调用方回退到自动模式）。
video_interactive_size() {
  local rebuild=1 line tok
  local -a menu=()
  local item a_h a_f a_b a_est a_ok i
  local vi_h=0 vi_f="" vi_b=0 vi_est=0 vi_ok=0
  local h f menu_trials
  local set_h="" set_f="" set_b="" set_size="" got=0
  local new_bytes new_base calc total_kbps
  local need_cal bitrate_only est invalid

  while (( rebuild )); do
    rebuild=0
    menu=()
    menu_trials=0
    echo "正在试算候选档位（采样 ${sample_len}s 片段）..." >&2
    while read -r h f; do
      [[ "$f" == "-" ]] && f=""
      (( menu_trials >= 14 )) && break
      video_calibrate_profile "$h" "$f" "$base_kbps" "$floor_kbps" 2
      if (( cal_est > 0 )); then
        menu+=("$h|$f|$cal_b|$cal_est|$cal_ok")
        menu_trials=$(( menu_trials + cal_trials ))
      fi
      if (( ${#menu[@]} >= 4 )); then
        local any_ok=0
        for (( i = 0; i < ${#menu[@]}; i++ )); do
          item=${menu[$i]}
          [[ "${item##*|}" == "1" ]] && any_ok=1
        done
        (( any_ok )) && break
      fi
    done < "$top_file"

    if (( ${#menu[@]} == 0 )); then
      echo "提示: 试算失败，改用自动模式。" >&2
      return 1
    fi

    # 默认选第一个符合目标的方案；都不符合则选预计最小的
    local cur_i=0 cur_est=0
    for (( i = 0; i < ${#menu[@]}; i++ )); do
      item=${menu[$i]}
      a_h=${item%%|*}; item=${item#*|}
      a_f=${item%%|*}; item=${item#*|}
      a_b=${item%%|*}; item=${item#*|}
      a_est=${item%%|*}; a_ok=${item#*|}
      if [[ "$a_ok" == "1" ]]; then
        cur_i=$i
        break
      fi
      if (( cur_est == 0 )) || (( a_est < cur_est )); then
        cur_i=$i
        cur_est=$a_est
      fi
    done
    video_load_menu_item "${menu[$cur_i]}"

    while :; do
      printf '可选方案（目标 %s，源 %s）:\n' "$(human_bytes "$vopt_target_bytes")" "$(human_bytes "$src_bytes")"
      for (( i = 0; i < ${#menu[@]}; i++ )); do
        item=${menu[$i]}
        a_h=${item%%|*}; item=${item#*|}
        a_f=${item%%|*}; item=${item#*|}
        a_b=${item%%|*}; item=${item#*|}
        a_est=${item%%|*}; a_ok=${item#*|}
        local mark=" 超出目标"
        [[ "$a_ok" == "1" ]] && mark=" 符合目标"
        local fps_txt=""
        if [[ -n "$a_f" ]]; then fps_txt="@$(fps_display "$a_f")fps"; fi
        printf '  [%d] %4sp%-9s 视频 %5dkbps  预计 %s%s\n' \
          "$(( i + 1 ))" "$a_h" "$fps_txt" "$a_b" "$(human_bytes "$a_est")" "$mark"
      done
      local cur_fps_txt=""
      if [[ -n "$vi_f" ]]; then cur_fps_txt="@$(fps_display "$vi_f")fps"; fi
      printf '当前方案: %sp%s 视频 %dkbps，预计 %s' \
        "$vi_h" "$cur_fps_txt" "$vi_b" "$(human_bytes "$vi_est")"
      if [[ "$vi_ok" == "1" ]]; then printf '（符合目标）\n'; else printf '（超出目标）\n'; fi
      printf '选择编号，或输入 r720 / f24 / b5000k / s150M 调整；回车=确认，a=重算，q=退出: '
      if ! IFS= read -r line; then
        echo
        die "已取消转换"
      fi
      line=${line//,/ }
      line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [[ -z "$line" ]]; then
        isel_h=$vi_h; isel_f=$vi_f; isel_b=$vi_b; isel_est=$vi_est
        return 0
      fi
      case "$line" in
        a|A) rebuild=1; break ;;
        q|Q) die "已取消转换" ;;
      esac

      if [[ "$line" =~ ^[0-9]+$ ]]; then
        if (( line >= 1 && line <= ${#menu[@]} )); then
          video_load_menu_item "${menu[$(( line - 1 ))]}"
          printf '已选择 [%d]: %sp%s 视频 %dkbps，预计 %s\n' \
            "$line" "$vi_h" "$( [[ -n "$vi_f" ]] && echo "@$(fps_display "$vi_f")fps" )" \
            "$vi_b" "$(human_bytes "$vi_est")"
          if [[ "$vi_ok" != "1" ]]; then
            echo "注意: 该方案预计超出目标，成片可能偏大。"
          fi
          if video_confirm_plan; then
            isel_h=$vi_h; isel_f=$vi_f; isel_b=$vi_b; isel_est=$vi_est
            return 0
          else
            local rc2=$?
            (( rc2 == 2 )) && die "已取消转换"
          fi
        else
          echo "编号需在 1-${#menu[@]} 之间"
        fi
        continue
      fi

      set_h=""; set_f=""; set_b=""; set_size=""
      invalid=0
      for tok in $line; do
        case "$tok" in
          r*)
            local rh=${tok#r}
            rh=${rh%p}
            if ! [[ "$rh" =~ ^[0-9]+$ ]] || (( rh <= 0 )); then
              echo "分辨率写法示例: r720"
              invalid=1
              break
            fi
            if (( rh > src_h_num )); then
              echo "分辨率不能超过源高度 ${src_h_num}p（需要放大请直接指定 -r）"
              invalid=1
              break
            fi
            set_h=$rh
            ;;
          f*)
            local rf=${tok#f}
            if ! [[ "$rf" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v f="$rf" 'BEGIN { exit !(f > 0) }'; then
              echo "帧率写法示例: f24"
              invalid=1
              break
            fi
            set_f=$rf
            ;;
          b*)
            if ! parse_bitrate "${tok#b}"; then
              echo "码率写法示例: b5000k / b5M"
              invalid=1
              break
            fi
            set_b=$bitrate_kbps
            ;;
          s*)
            if ! parse_size "${tok#s}"; then
              echo "大小写法示例: s150M / s700K"
              invalid=1
              break
            fi
            if (( target_bytes >= src_bytes )); then
              echo "目标大小需小于源文件 $(human_bytes "$src_bytes")"
              invalid=1
              break
            fi
            set_size=$target_bytes
            ;;
          *)
            echo "无法识别: $tok"
            invalid=1
            break
            ;;
        esac
      done
      (( invalid )) && continue

      if [[ -n "$set_size" ]]; then
        new_bytes=$set_size
        calc=$(awk -v bytes="$new_bytes" -v dur="$src_duration" -v ak="$audio_kbps" \
          'BEGIN { total = bytes * 8 / dur / 1000 * 0.97; v = total - ak; printf "%d %d", total, v }')
        total_kbps=${calc% *}
        new_base=${calc#* }
        if (( new_base < 100 )); then
          echo "目标太小（可用视频码率仅 ${new_base}kbps），请调大"
          continue
        fi
        vopt_target_bytes=$new_bytes
        vopt_size=$(size_arg "$new_bytes")
        base_kbps=$new_base
        audio_est=$(awk -v ak="$audio_kbps" -v d="$src_duration" 'BEGIN { printf "%.0f", ak * 1000 / 8 * d }')
        video_target=$(( vopt_target_bytes - audio_est ))
        (( video_target < 1 )) && video_target=1
        floor_kbps=$(awk -v b="$base_kbps" 'BEGIN { n = b * 0.35; if (n < 64) n = 64; printf "%d", n }')
        rebuild=1
        break
      fi

      got=0
      if [[ -n "$set_h" ]]; then vi_h=$set_h; got=1; fi
      if [[ -n "$set_f" ]]; then vi_f=$set_f; got=1; fi
      if [[ -n "$set_b" ]]; then vi_b=$set_b; got=1; fi
      if (( ! got )); then continue; fi

      if [[ -n "$set_h" || -n "$set_f" ]]; then
        bitrate_only=0
        [[ -n "$set_b" ]] && bitrate_only=1
        if (( bitrate_only )); then
          vi_est=$(video_sample_estimate "$vi_h" "$vi_f" "$vi_b") || vi_est=0
        else
          video_calibrate_profile "$vi_h" "$vi_f" "$base_kbps" "$floor_kbps" 3
          vi_b=$cal_b
          vi_est=$cal_est
          vi_ok=$cal_ok
        fi
      else
        vi_est=$(video_sample_estimate "$vi_h" "$vi_f" "$vi_b") || vi_est=0
      fi
      if (( vi_est <= 0 )); then
        echo "该组合试算失败，请调整参数"
        continue
      fi
      if (( vi_est <= vopt_target_bytes )); then vi_ok=1; else vi_ok=0; fi

      local cur_fps2=""
      if [[ -n "$vi_f" ]]; then cur_fps2="@$(fps_display "$vi_f")fps"; fi
      printf '当前方案: %sp%s 视频 %dkbps，预计 %s' \
        "$vi_h" "$cur_fps2" "$vi_b" "$(human_bytes "$vi_est")"
      if [[ "$vi_ok" == "1" ]]; then printf '（符合目标）\n'; else printf '（超出目标）\n'; fi
      if [[ "$vi_ok" != "1" ]]; then
        echo "注意: 该方案预计超出目标，成片可能偏大。"
      fi
      if video_confirm_plan; then
        isel_h=$vi_h; isel_f=$vi_f; isel_b=$vi_b; isel_est=$vi_est
        return 0
      else
        local rc3=$?
        (( rc3 == 2 )) && die "已取消转换"
      fi
    done
  done
  return 1
}

# 单文件 video 转换。依赖 do_video 设置的 vopt_* / vc_* 全局变量。
video_one() {
  local input=$1 output=$2
  require_ffmpeg
  [[ -f "$input" ]] || die "输入文件不存在: $input"

  # ---------- 探测源 ----------
  local src_vcodec src_acodec src_width src_height src_fps src_duration src_bytes
  local src_sr src_ch src_abit
  src_vcodec=$(ffprobe_field "$input" v:0 codec_name)
  [[ -n "$src_vcodec" ]] || die "输入没有视频流: $input"
  src_width=$(ffprobe_field "$input" v:0 width)
  src_height=$(ffprobe_field "$input" v:0 height)
  src_fps=$(ffprobe_field "$input" v:0 avg_frame_rate)
  [[ "$src_fps" =~ ^[0-9]+/[1-9][0-9]*$ ]] || src_fps=$(ffprobe_field "$input" v:0 r_frame_rate)
  src_acodec=$(ffprobe_field "$input" a:0 codec_name)
  src_sr=$(ffprobe_field "$input" a:0 sample_rate)
  src_ch=$(ffprobe_field "$input" a:0 channels)
  src_abit=$(ffprobe_field "$input" a:0 bit_rate)
  src_duration=$(ffprobe_field "$input" "" duration)
  src_bytes=$(ffprobe_field "$input" "" size)

  local duration_ok
  duration_ok=$(awk -v d="$src_duration" 'BEGIN { print (d ~ /^[0-9]+([.][0-9]+)?$/ && d > 0) ? 1 : 0 }')
  if (( duration_ok == 0 )); then
    src_duration=$(ffprobe_field "$input" v:0 duration)
  fi
  [[ "$src_bytes" =~ ^[0-9]+$ ]] || src_bytes=$(stat -f%z "$input" 2>/dev/null || stat -c%s "$input" 2>/dev/null || echo 0)

  local src_fps_display
  src_fps_display=$(fps_display "$src_fps")
  local src_dim="${src_width}x${src_height}"
  [[ -n "$src_width" && -n "$src_height" ]] || src_dim="?"

  local has_audio=0
  [[ -n "$src_acodec" ]] && has_audio=1

  # ---------- 源信息摘要 ----------
  local src_vbit src_container
  src_vbit=$(ffprobe_field "$input" v:0 bit_rate)
  src_container=${input##*/}
  src_container=${src_container##*.}

  printf '源文件: %s（%s' "$input" "$(human_bytes "$src_bytes")"
  if [[ "$src_duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '，%s' "$(human_duration "$src_duration")"
  fi
  printf '，%s）\n' "$src_container"
  local vdesc="$src_vcodec"
  if [[ "$src_width" =~ ^[0-9]+$ && "$src_height" =~ ^[0-9]+$ ]]; then
    vdesc="$vdesc ${src_width}x${src_height}"
  fi
  if [[ -n "$src_fps_display" && "$src_fps_display" != "?" ]]; then
    vdesc="$vdesc@${src_fps_display}fps"
  fi
  if [[ "$src_vbit" =~ ^[0-9]+$ ]] && (( src_vbit > 0 )); then
    vdesc="${vdesc}（$(human_bitrate "$src_vbit")）"
  fi
  printf '视频: %s\n' "$vdesc"
  if (( has_audio )); then
    local adesc="$src_acodec"
    if [[ "$src_sr" =~ ^[0-9]+$ ]]; then adesc="$adesc ${src_sr}Hz"; fi
    if [[ "$src_ch" =~ ^[0-9]+$ ]]; then adesc="$adesc ${src_ch}ch"; fi
    if [[ "$src_abit" =~ ^[0-9]+$ ]] && (( src_abit > 0 )); then
      adesc="${adesc}（$(human_bitrate "$src_abit")）"
    fi
    printf '音频: %s\n' "$adesc"
  else
    printf '音频: 无\n'
  fi
  echo

  if (( vopt_interactive )) && (( ! vopt_size_active )) && (( ! vopt_size_given )); then
    local ans
    printf '目标大小（如 200M；回车=按高画质转换）: '
    if ! IFS= read -r ans; then ans=""; fi
    if [[ -n "$ans" ]]; then
      parse_size "$ans" || die "目标大小格式无效: ${ans}"
      vopt_size=$ans
      vopt_size_active=1
      vopt_target_bytes=$target_bytes
    else
      echo "未指定目标大小，按高画质转换。"
    fi
  fi

  # ---------- 视频侧：是否流复制 ----------
  local copy_video=0 rate_mode=quality wants_encode=0
  if (( vopt_force_copy )); then
    if ! video_codec_allowed "$vc_copyv" "$src_vcodec"; then
      die "视频 $src_vcodec 不能直接放入 $vc_name 容器（容器支持: ${vc_copyv# }）；去掉 --copy 让脚本自动重编码"
    fi
    copy_video=1
  else
    if [[ -n "$vopt_codec" || -n "$vopt_resolution" || -n "$vopt_fps" || -n "$vopt_crf" || -n "$vopt_bitrate" ]]; then
      wants_encode=1
    fi
    if (( vopt_size_active )); then
      if (( src_bytes > 0 )) && (( vopt_target_bytes >= src_bytes )); then
        if (( ! wants_encode )) && video_codec_allowed "$vc_copyv" "$src_vcodec"; then
          echo "提示: 目标大小 $(human_bytes "$vopt_target_bytes") 不小于源文件 $(human_bytes "$src_bytes")，直接流复制。" >&2
          copy_video=1
        else
          echo "提示: 目标大小 $(human_bytes "$vopt_target_bytes") 不小于源文件 $(human_bytes "$src_bytes")，改用高画质重编码。" >&2
        fi
      else
        wants_encode=1
        rate_mode=size
      fi
    fi
    if [[ -n "$vopt_bitrate" ]]; then
      rate_mode=bitrate
    fi
    if (( ! copy_video )) && (( ! wants_encode )) && video_codec_allowed "$vc_copyv" "$src_vcodec"; then
      copy_video=1
    fi
  fi

  # ---------- 音频策略 ----------
  local audio_mode=none audio_kbps=0 audio_enc=""
  local -a a_args=()
  local -a map_args=(-map 0:v:0)
  if (( has_audio )) && [[ "$vopt_audio_mode" != none ]]; then
    map_args+=(-map 0:a:0?)
    if [[ "$vopt_audio_mode" == copy ]]; then
      if ! video_codec_allowed "$vc_copya" "$src_acodec"; then
        if (( vopt_force_copy )); then
          die "音频 $src_acodec 不能直接放入 $vc_name 容器；请用 -a 192k 重编码音频，或去掉 --copy"
        fi
        die "音频 $src_acodec 不能直接放入 $vc_name 容器；请用 -a auto 或 -a 192k 重编码音频"
      fi
      a_args=(-c:a copy)
      audio_mode=copy
    elif [[ "$vopt_audio_mode" == auto ]] && video_codec_allowed "$vc_copya" "$src_acodec"; then
      a_args=(-c:a copy)
      audio_mode=copy
    else
      audio_enc=$vc_aenc
      if [[ -n "$vopt_acodec" ]]; then audio_enc=$vopt_acodec; fi
      case " $vc_aencs " in
        *" $audio_enc "*) ;;
        *) die "$vc_name 容器不支持音频编码: ${audio_enc}（可用: ${vc_aencs# }）" ;;
      esac
      have_encoder "$audio_enc" || die "当前 ffmpeg 缺少音频编码器: $audio_enc"
      local audio_bit_opt=$vopt_abitrate
      if [[ -z "$audio_bit_opt" ]]; then
        audio_codec_info "$audio_enc"
        if [[ "$ac_kind" == lossy ]]; then audio_bit_opt=$vc_abit; fi
      fi
      audio_build_encode "$audio_enc" "$audio_bit_opt" "$vopt_arate" "$vopt_achannels" "$src_sr" "$src_ch"
      a_args=("${aa_args[@]}")
      audio_mode=encode
    fi
  else
    a_args=(-an)
  fi

  if [[ "$audio_mode" == encode ]]; then
    if [[ "$aa_kind" == lossy ]]; then
      parse_bitrate "$aa_bit" || die "音频码率无效: $aa_bit"
      audio_kbps=$bitrate_kbps
    else
      if [[ "$src_abit" =~ ^[0-9]+$ ]] && (( src_abit > 0 )); then
        audio_kbps=$(( src_abit / 1000 ))
      else
        audio_kbps=128
      fi
      if [[ "$rate_mode" == size ]]; then
        echo "提示: 音频为无损编码，-s 只能按源音频码率估算，实际大小可能超出目标。" >&2
      fi
    fi
  elif [[ "$audio_mode" == copy ]]; then
    if [[ "$src_abit" =~ ^[0-9]+$ ]] && (( src_abit > 0 )); then
      audio_kbps=$(( src_abit / 1000 ))
    else
      audio_kbps=128
    fi
  fi

  # ---------- 编码参数 ----------
  local enc="" qfamily="" qval=0 two_pass=0 v_kbps=0
  local -a v_args=() vf_args=() fps_args=()
  if (( copy_video )); then
    v_args=(-c:v copy)
  else
    enc=$vc_venc
    if [[ -n "$vopt_codec" ]]; then enc=$vopt_codec; fi
    video_resolve_encoder "$enc"
    enc=$video_encoder
    video_codec_family "$enc"
    qfamily=$vc_family

    if [[ -n "$vopt_crf" ]]; then
      qval=$vopt_crf
    else
      qval=$vc_qdefault
    fi
    if [[ "$qfamily" == crf ]]; then
      (( qval >= 0 && qval <= 63 )) || die "-q/--crf 对 $enc 的取值范围是 0-63（越小越清晰）"
    elif [[ "$qfamily" == vt ]]; then
      (( qval >= 0 && qval <= 100 )) || die "-q/--crf 对 $enc 是硬件画质，范围 0-100（越大越清晰）"
    else
      (( qval >= 1 && qval <= 31 )) || die "-q/--crf 对 $enc 是 qscale（范围 1-31，越小越清晰）"
    fi

    if [[ -n "$vopt_resolution" ]]; then
      case "$vopt_resolution" in
        *[pP])
          local rh=${vopt_resolution%?}
          vf_args=(-vf "scale=-2:${rh}:flags=lanczos")
          ;;
        *[xX]*)
          local rw=${vopt_resolution%%[xX]*}
          local rh2=${vopt_resolution##*[xX]}
          vf_args=(-vf "scale=${rw}:${rh2}:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos")
          ;;
        *)
          vf_args=(-vf "scale=-2:${vopt_resolution}:flags=lanczos")
          ;;
      esac
    fi
    if [[ -n "$vopt_fps" ]]; then
      fps_args=(-r "$vopt_fps")
    fi

    v_args=(-c:v "$enc")
    if [[ "$rate_mode" == quality ]]; then
      case "$qfamily" in
        crf)
          v_args+=(-crf "$qval")
          case "$enc" in
            libvpx|libvpx-vp9) v_args+=(-b:v 0) ;;
          esac
          ;;
        vt) v_args+=(-q:v "$qval") ;;
        *)  v_args+=(-qscale:v "$qval") ;;
      esac
    fi
    case "$enc" in
      libx264|libx265) v_args+=(-preset "$vopt_preset") ;;
    esac
    case "$enc" in
      libx265) v_args+=(-x265-params log-level=error) ;;
      libvpx|libvpx-vp9) v_args+=(-row-mt 1 -deadline good -cpu-used 2) ;;
      libsvtav1) v_args+=(-preset 8) ;;
    esac
    case "$enc" in
      wmv2|mpeg4|mpeg2video|mjpeg|libxvid|libvpx|libvpx-vp9|libx264|libx265|libsvtav1|libaom-av1|libvvenc|h264_videotoolbox|hevc_videotoolbox|flv)
        v_args+=(-pix_fmt yuv420p) ;;
    esac
  fi

  local video_tmpdir
  video_tmpdir=$(mktemp -d)
  trap 'if [[ -n "${video_tmpdir:-}" ]]; then rm -rf "$video_tmpdir"; fi' EXIT

  local adapt_h=0 adapt_f="" adapt_est=0 adapt_warn=0 adapt_txt=""

  # 码率模式：-b 直接用；-s 从目标大小反推
  if [[ "$rate_mode" == size ]]; then
    local size_dur_ok
    size_dur_ok=$(awk -v d="$src_duration" 'BEGIN { print (d ~ /^[0-9]+([.][0-9]+)?$/ && d > 0) ? 1 : 0 }')
    (( size_dur_ok )) || die "无法获取视频时长，不能用 -s 推算码率；请改用 -b 指定码率"
    local calc
    calc=$(awk -v bytes="$vopt_target_bytes" -v dur="$src_duration" -v ak="$audio_kbps" \
      'BEGIN { total = bytes * 8 / dur / 1000 * 0.97; v = total - ak; printf "%d %d", total, v }')
    v_kbps=${calc#* }
    if (( v_kbps < 100 )); then
      die "目标大小 $vopt_size 太小（可用视频码率仅 ${v_kbps}kbps）；请增大目标大小或降低分辨率"
    fi

    local base_kbps=$v_kbps
    local has_ladder=0 interactive_done=0
    local src_h_num=0 src_fps_num=0
    local top_file="" sample_path="" sample_len="" start_s=""
    local audio_est=0 video_target=1 floor_kbps=0
    local cal_est=0 cal_b=0 cal_ok=0 cal_trials=0
    local isel_h=0 isel_f="" isel_b=0 isel_est=0

    # 构建 分辨率×帧率 档位表（用户已指定 -r/--fps 时不自动调整）
    if [[ "$src_height" =~ ^[0-9]+$ ]] && [[ -z "$vopt_resolution" && -z "$vopt_fps" ]]; then
      has_ladder=1
      src_h_num=$src_height
      if [[ "$src_fps" =~ ^([0-9]+)/([1-9][0-9]*)$ ]]; then
        src_fps_num=$(awk -v a="${BASH_REMATCH[1]}" -v b="${BASH_REMATCH[2]}" 'BEGIN { printf "%.3f", a / b }')
      fi

      local -a heights=("$src_h_num")
      local hh dup exist
      for hh in 1080 720 576 480 360 240; do
        if (( hh < src_h_num )); then
          dup=0
          for exist in "${heights[@]}"; do
            [[ "$exist" == "$hh" ]] && dup=1
          done
          (( dup )) || heights+=("$hh")
        fi
      done

      top_file="$video_tmpdir/top"
      : > "$top_file"
      local h base_f
      for h in "${heights[@]}"; do
        if [[ "$h" == "$src_h_num" ]]; then
          base_f=$src_fps
        elif awk -v f="$src_fps_num" 'BEGIN { exit !(f > 30.01) }'; then
          base_f=30
        else
          base_f=$src_fps
        fi
        [[ -z "$base_f" ]] && base_f="-"
        printf '%s %s\n' "$h" "$base_f" >> "$top_file"
        if [[ "$h" == "$src_h_num" ]] && awk -v f="$src_fps_num" 'BEGIN { exit !(f > 30.01) }'; then
          printf '%s 30\n' "$h" >> "$top_file"
        fi
      done
      local smallest=${heights[$((${#heights[@]} - 1))]}
      local lf
      for lf in 15 10; do
        if awk -v s="$src_fps_num" -v f="$lf" 'BEGIN { exit !(s > f + 0.01) }'; then
          printf '%s %s\n' "$smallest" "$lf" >> "$top_file"
        fi
      done

      sample_len=$(awk -v d="$src_duration" 'BEGIN { if (d <= 30) printf "%.1f", d; else printf "12" }')
      start_s=$(awk -v d="$src_duration" -v l="$sample_len" 'BEGIN { if (d <= l) printf "0"; else printf "%.1f", (d - l) * 0.35 }')
      audio_est=$(awk -v ak="$audio_kbps" -v d="$src_duration" 'BEGIN { printf "%.0f", ak * 1000 / 8 * d }')
      video_target=$(( vopt_target_bytes - audio_est ))
      (( video_target < 1 )) && video_target=1
      # 单档位最多把码率降到初始值的 35%，再低就换更低分辨率。
      floor_kbps=$(awk -v b="$base_kbps" 'BEGIN { n = b * 0.35; if (n < 64) n = 64; printf "%d", n }')
      sample_path="$video_tmpdir/sample.${vc_ext}"
    fi

    # 交互式挑选档位（对所有编码器开放，最终仍按编码器能力走两遍/单遍）
    if (( vopt_interactive )); then
      if (( has_ladder )); then
        if video_interactive_size; then
          adapt_h=$isel_h
          adapt_f=$isel_f
          adapt_est=$isel_est
          v_kbps=$isel_b
          interactive_done=1
        fi
      else
        echo "提示: 缺少源分辨率信息，无法生成档位菜单，改为自动模式。" >&2
      fi
    fi

    if video_supports_two_pass "$enc"; then
      two_pass=1
      v_args+=(-b:v "${v_kbps}k")
    else
      # 非两遍编码器：自动校准码率，压不进目标再降分辨率/帧率
      if (( ! interactive_done )) && (( has_ladder )) && (( ! vopt_no_adapt )); then
        local t_h t_f t_f_disp
        local chosen_found=0 trials=0
        local min_h=0 min_f="" min_b=0 min_est=0
        echo "试算中（采样 ${sample_len}s 片段）..." >&2
        while read -r t_h t_f; do
          [[ "$t_f" == "-" ]] && t_f=""
          t_f_disp=""
          if [[ -n "$t_f" ]]; then t_f_disp="@$(fps_display "$t_f")"; fi
          if (( trials >= 12 )); then break; fi
          video_calibrate_profile "$t_h" "$t_f" "$base_kbps" "$floor_kbps" 3
          trials=$(( trials + cal_trials ))
          if (( cal_est == 0 )); then continue; fi
          echo "试算: ${t_h}p${t_f_disp} ${cal_b}kbps → 预计 $(human_bytes "$cal_est")（目标 $(human_bytes "$vopt_target_bytes")）" >&2
          if (( min_est == 0 )) || (( cal_est < min_est )); then
            min_h=$t_h
            min_f=$t_f
            min_b=$cal_b
            min_est=$cal_est
          fi
          if (( cal_ok )); then
            adapt_h=$t_h
            adapt_f=$t_f
            adapt_est=$cal_est
            v_kbps=$cal_b
            chosen_found=1
            break
          fi
        done < "$top_file"

        if (( chosen_found )); then
          if (( adapt_h < src_h_num )) || [[ -n "$adapt_f" && "$adapt_f" != "$src_fps" ]]; then
            adapt_txt="，自适应 ${adapt_h}p"
          elif (( v_kbps != base_kbps )); then
            adapt_txt="，码率校准"
          fi
        elif (( min_h > 0 )); then
          adapt_h=$min_h
          adapt_f=$min_f
          adapt_est=$min_est
          v_kbps=$min_b
          adapt_warn=1
          adapt_txt="，已降到 ${adapt_h}p"
        fi
      fi
      v_args+=(-b:v "${v_kbps}k" -maxrate "$(( v_kbps * 12 / 10 ))k" -bufsize "$(( v_kbps * 2 ))k")
    fi

    # 应用选定的分辨率/帧率与说明文字
    if (( adapt_h > 0 )); then
      if (( adapt_h < src_h_num )); then
        vf_args=(-vf "scale=-2:${adapt_h}:flags=lanczos")
      fi
      if [[ -n "$adapt_f" && "$adapt_f" != "$src_fps" ]]; then
        fps_args=(-r "$adapt_f")
      fi
      if (( interactive_done )); then
        adapt_txt="，已选 ${adapt_h}p"
      fi
      if [[ -n "$adapt_txt" && -n "$adapt_f" ]]; then
        adapt_txt="$adapt_txt@$(fps_display "$adapt_f")fps"
      fi
    fi
  elif [[ "$rate_mode" == bitrate ]]; then
    v_kbps=$vopt_bitrate_kbps
    v_args+=(-b:v "${v_kbps}k")
  fi

  # ---------- 容器与元数据 ----------
  local -a meta_args=(-map_metadata 0)
  case "$vc_name" in
    mp4|m4v|mov|mkv) meta_args+=(-map_chapters 0) ;;
    *) meta_args+=(-map_chapters -1) ;;
  esac
  local -a mux_args=(-f "$vc_muxer")
  if (( vc_faststart )); then mux_args+=(-movflags +faststart); fi
  # mp4/mov 里的 HEVC 打 hvc1 标签，否则 macOS/QuickTime 可能拒绝播放。
  if [[ -n "$enc" ]]; then
    case "$vc_name" in
      mp4|m4v|mov)
        if [[ "$(video_encoder_codec "$enc")" == hevc ]]; then mux_args+=(-tag:v hvc1); fi
        ;;
    esac
  fi

  if [[ "$vc_name" == wmv ]] && [[ "$src_width" =~ ^[0-9]+$ ]] && [[ "$src_height" =~ ^[0-9]+$ ]] \
     && (( src_width > 1920 || src_height > 1080 )); then
    echo "提示: 源为 ${src_width}x${src_height}，部分 Windows 播放器对 WMV 超过 1080p 支持有限；可加 -r 1080p。" >&2
  fi

  # ---------- 执行 ----------
  local -a base=(ffmpeg -hide_banner -nostdin -loglevel error -stats -y -i "$input")
  base+=("${map_args[@]}")
  if (( ${#vf_args[@]} > 0 )); then base+=("${vf_args[@]}"); fi
  if (( ${#fps_args[@]} > 0 )); then base+=("${fps_args[@]}"); fi
  base+=("${v_args[@]}")

  local passlog="$video_tmpdir/passlog"
  if (( two_pass )); then
    if ! "${base[@]}" -pass 1 -passlogfile "$passlog" -an -f null /dev/null; then
      die "两遍编码第一遍失败: $input"
    fi
  fi

  local -a final_cmd=("${base[@]}")
  if (( two_pass )); then final_cmd+=(-pass 2 -passlogfile "$passlog"); fi
  final_cmd+=("${a_args[@]}")
  final_cmd+=("${meta_args[@]}")
  final_cmd+=("${mux_args[@]}")
  final_cmd+=("$output")
  if ! "${final_cmd[@]}"; then
    die "转码失败: $input"
  fi

  [[ -f "$output" ]] || die "编码未生成输出文件: $output"

  # ---------- 结果报告 ----------
  local out_bytes out_w out_h out_vcodec out_dim out_fps out_fps_display
  out_bytes=$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output")
  out_w=$(ffprobe_field "$output" v:0 width)
  out_h=$(ffprobe_field "$output" v:0 height)
  out_vcodec=$(ffprobe_field "$output" v:0 codec_name)
  out_fps=$(ffprobe_field "$output" v:0 avg_frame_rate)
  out_fps_display=$(fps_display "$out_fps")
  if [[ "$out_w" =~ ^[0-9]+$ && "$out_h" =~ ^[0-9]+$ ]]; then
    out_dim="${out_w}x${out_h}"
  else
    out_dim="?"
  fi

  local video_line audio_line mode_line
  if (( copy_video )); then
    video_line="${src_vcodec} ${src_dim}@${src_fps_display} -> 流复制"
  else
    video_line="${src_vcodec} ${src_dim}@${src_fps_display} -> ${out_vcodec} ${out_dim}@${out_fps_display}"
  fi
  case "$audio_mode" in
    none) audio_line="无（未包含音轨）" ;;
    copy) audio_line="${src_acodec} -> 流复制" ;;
    encode)
      audio_line="${src_acodec} -> ${audio_enc}"
      if [[ "$aa_kind" == lossy ]]; then
        audio_line="$audio_line ${aa_bit}"
      else
        audio_line="$audio_line 无损"
      fi
      if (( aa_rate_changed )); then audio_line="$audio_line ${aa_rate}Hz"; fi
      if (( aa_ch_changed )); then audio_line="$audio_line ${aa_ch}ch"; fi
      ;;
  esac
  if (( copy_video )); then
    if [[ "$audio_mode" == encode ]]; then
      mode_line="视频流复制（音频重编码）"
    else
      mode_line="流复制（无重编码）"
    fi
  elif [[ "$rate_mode" == size ]]; then
    if (( two_pass )); then
      mode_line="目标大小 ${vopt_size}（两遍编码，视频 ${v_kbps}kbps${adapt_txt}）"
    else
      mode_line="目标大小 ${vopt_size}（单遍编码，视频 ${v_kbps}kbps${adapt_txt}）"
    fi
  elif [[ "$rate_mode" == bitrate ]]; then
    mode_line="指定码率（视频 ${v_kbps}kbps）"
  else
    case "$qfamily" in
      crf) mode_line="高画质重编码（${enc} crf=${qval}）" ;;
      vt)  mode_line="高画质重编码（${enc} 硬件画质=${qval}）" ;;
      *)   mode_line="高画质重编码（${enc} qscale=${qval}）" ;;
    esac
  fi

  printf '已生成: %s\n' "$output"
  printf '视频: %s\n' "$video_line"
  printf '音频: %s\n' "$audio_line"
  printf '方式: %s\n' "$mode_line"
  printf '大小: %s -> %s' "$(human_bytes "$src_bytes")" "$(human_bytes "$out_bytes")"
  if [[ "$src_duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '，时长 %s' "$(human_duration "$src_duration")"
  fi
  printf '，分辨率 %s\n' "$out_dim"

  if [[ "$rate_mode" == size ]] && (( adapt_warn )); then
    echo "提示: 已降到 ${adapt_h}p 试算仍可能超出目标，正片可能偏大；可进一步用 -r 降分辨率或增大 -s。" >&2
  fi

  if [[ "$rate_mode" == size ]] && (( out_bytes > vopt_target_bytes * 12 / 10 )); then
    if [[ "$audio_mode" == encode && "$aa_kind" == lossless ]]; then
      echo "提示: 无损音轨体积不可控，实际大小超出目标 20% 以上；可改用有损音频（如 -a 192k）或增大目标。" >&2
    elif (( adapt_h > 0 )); then
      echo "提示: 实际大小超出目标 20% 以上；该编码器码率控制较弱，可再降低 -r 或增大 -s。" >&2
    else
      echo "提示: 实际大小超出目标 20% 以上；可加 -r 降低分辨率或改用 -q 指定画质。" >&2
    fi
  fi
  return 0
}

# ---------- audio 子命令 ----------
audio_usage() {
  cat <<'EOF'
用法:
  media.sh audio -i INPUT [-f FORMAT] [-b BITRATE | -s SIZE] [选项] [-o OUTPUT]

从视频或音频中提取音轨、转换音频格式（默认 m4a）。
  -i, --input       输入文件或目录（目录时递归批量）
  -f, --format      输出格式: m4a, mp3, aac, flac, wav, opus, ogg, wma, ac3, mka
                    （默认 m4a；给出 -o 时也可由扩展名推断）
  -o, --output      输出文件（单文件）或输出目录（批量）
  -b, --bitrate     音频码率（如 192k、320k；flac/wav 等无损格式忽略）
  -s, --size        目标大小（K/M/G=1000 进制，如 20M、300K），按音频码率反推
                    -  表示不做大小压缩（默认行为）
  --acodec NAME     指定音频编码器：aac、mp3、opus、vorbis、flac、alac、ac3、eac3、mp2、wma、pcm
                    （默认按格式选择；容器不支持时报错）
  --ar RATE         采样率（如 44100、48000），默认保持原始
  --ac N            声道数（1 单声道、2 立体声、6 5.1），默认保持原始
  --copy            直接复制音频流（不重编码），容器/编码不兼容时报错
  -h, --help        显示帮助

说明:
  · 默认能流复制就流复制（如 mp4/mkv 的 aac → m4a），否则按格式默认编码器转码。
  · 仅提取第一条音频流；视频画面、字幕不保留。
  · -b/-s 只对 aac/mp3/opus/vorbis/wma/ac3/eac3/mp2 等有损编码生效。
  · 采样率/声道超出编码器支持时会报错（未指定时自动降到编码器上限）。

示例:
  media.sh audio -i movie.mp4                    # 提取为 m4a（aac 源直接复制）
  media.sh audio -i movie.mp4 -f mp3 -b 320k     # 转 mp3 320k
  media.sh audio -i movie.mkv -f flac            # 转无损 flac
  media.sh audio -i movie.ts -f wav --ac 1       # 转单声道 wav
  media.sh audio -i song.flac -f opus --ar 48000 --ac 2
  media.sh audio -i ./videos -f mp3 -o ./audio   # 目录批量
EOF
}

audio_canonical_format() {
  case "$1" in
    m4a|m4b|mp4) printf 'm4a\n' ;;
    mp3) printf 'mp3\n' ;;
    aac|adts) printf 'aac\n' ;;
    flac) printf 'flac\n' ;;
    wav|wave) printf 'wav\n' ;;
    opus) printf 'opus\n' ;;
    ogg|oga|vorbis) printf 'ogg\n' ;;
    wma|asf) printf 'wma\n' ;;
    ac3) printf 'ac3\n' ;;
    mka|mkv) printf 'mka\n' ;;
    *) return 1 ;;
  esac
}

audio_format_from_path() {
  local base=${1##*/}
  [[ "$base" == *.* ]] || return 1
  audio_canonical_format "$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')"
}

# 音频容器属性通过 af_* 全局变量返回。
audio_format_info() {
  af_name=$1
  case "$1" in
    m4a)
      af_ext=m4a; af_muxer=ipod; af_enc=aac; af_faststart=1
      af_encs=" aac alac "; af_copy=" aac alac " ;;
    mp3)
      af_ext=mp3; af_muxer=mp3; af_enc=libmp3lame; af_faststart=0
      af_encs=" libmp3lame "; af_copy=" mp3 " ;;
    aac)
      af_ext=aac; af_muxer=adts; af_enc=aac; af_faststart=0
      af_encs=" aac "; af_copy=" aac " ;;
    flac)
      af_ext=flac; af_muxer=flac; af_enc=flac; af_faststart=0
      af_encs=" flac "; af_copy=" flac " ;;
    wav)
      af_ext=wav; af_muxer=wav; af_enc=pcm_s16le; af_faststart=0
      af_encs=" pcm_s16le pcm_s24le pcm_s32le pcm_f32le "
      af_copy=" pcm_s16le pcm_s24le pcm_s32le pcm_f32le " ;;
    opus)
      af_ext=opus; af_muxer=opus; af_enc=libopus; af_faststart=0
      af_encs=" libopus "; af_copy=" opus " ;;
    ogg)
      af_ext=ogg; af_muxer=ogg; af_enc=libvorbis; af_faststart=0
      af_encs=" libvorbis libopus "; af_copy=" vorbis opus " ;;
    wma)
      af_ext=wma; af_muxer=asf; af_enc=wmav2; af_faststart=0
      af_encs=" wmav2 wmav1 "; af_copy=" wmav1 wmav2 pcm_s16le " ;;
    ac3)
      af_ext=ac3; af_muxer=ac3; af_enc=ac3; af_faststart=0
      af_encs=" ac3 "; af_copy=" ac3 " ;;
    mka)
      af_ext=mka; af_muxer=matroska; af_enc=aac; af_faststart=0
      af_encs=" aac libmp3lame libopus libvorbis flac alac ac3 eac3 mp2 wmav2 pcm_s16le "
      af_copy="*" ;;
  esac
}

do_audio() {
  local input="" format="" output=""
  aopt_bitrate=""; aopt_size=""; aopt_size_active=0; aopt_target_bytes=0
  aopt_acodec=""; aopt_rate=""; aopt_channels=""; aopt_force_copy=0

  while (( $# > 0 )); do
    case "$1" in
      -i|--input) input=$2; shift 2 ;;
      -f|--format) format=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'); shift 2 ;;
      -o|--output) output=$2; shift 2 ;;
      -b|--bitrate) aopt_bitrate=$2; shift 2 ;;
      -s|--size) aopt_size=$2; shift 2 ;;
      --acodec|--audio-codec) aopt_acodec=$2; shift 2 ;;
      --ar|--audio-rate|--sample-rate) aopt_rate=$2; shift 2 ;;
      --ac|--audio-channels|--channels) aopt_channels=$2; shift 2 ;;
      --copy) aopt_force_copy=1; shift ;;
      -h|--help) audio_usage; exit 0 ;;
      *) echo "未知参数: $1" >&2; audio_usage; exit 2 ;;
    esac
  done
  [[ -n "$input" ]] || { echo "错误: 缺少 -i/--input" >&2; audio_usage; exit 2; }

  # ---------- 目标格式 ----------
  if [[ -z "$format" && -n "$output" && ! -d "$output" ]]; then
    format=$(audio_format_from_path "$output" || true)
  fi
  [[ -n "$format" ]] || format=m4a
  local canonical
  if ! canonical=$(audio_canonical_format "$format"); then
    die "不支持的音频格式: ${format}（可用: m4a、mp3、aac、flac、wav、opus、ogg、wma、ac3、mka）"
  fi
  format=$canonical
  audio_format_info "$format"

  # ---------- 参数校验 ----------
  if [[ "$aopt_size" == "-" ]]; then
    aopt_size=""
  elif [[ -n "$aopt_size" ]]; then
    parse_size "$aopt_size" || die "目标大小格式无效: ${aopt_size}（示例: 20M、300K）"
    aopt_size_active=1
    aopt_target_bytes=$target_bytes
  fi

  if [[ -n "$aopt_bitrate" ]]; then
    parse_bitrate "$aopt_bitrate" || die "码率格式无效: ${aopt_bitrate}（示例: 192k、320k）"
    (( aopt_size_active )) && die "-b/--bitrate 与 -s/--size 只能二选一"
  fi

  if [[ -n "$aopt_acodec" ]]; then
    local mapped
    if ! mapped=$(audio_encoder_name "$aopt_acodec"); then
      die "未知音频编码器: ${aopt_acodec}（可用: aac、mp3、opus、vorbis、flac、alac、ac3、eac3、mp2、wma、pcm）"
    fi
    aopt_acodec=$mapped
    if [[ "$aopt_acodec" == copy ]]; then
      aopt_acodec=""
      aopt_force_copy=1
    fi
  fi

  if [[ -n "$aopt_rate" ]]; then
    [[ "$aopt_rate" =~ ^[0-9]+$ ]] || die "采样率无效: $aopt_rate"
  fi
  if [[ -n "$aopt_channels" ]]; then
    [[ "$aopt_channels" =~ ^[1-9][0-9]*$ ]] || die "声道数无效: $aopt_channels"
  fi

  if (( aopt_force_copy )); then
    if [[ -n "$aopt_acodec" || -n "$aopt_rate" || -n "$aopt_channels" || -n "$aopt_bitrate" ]] || (( aopt_size_active )); then
      die "--copy 不能与 -b/-s/--acodec/--ar/--ac 同时使用"
    fi
  fi

  # ---------- 目录批量 ----------
  if [[ -d "$input" ]]; then
    local output_dir=${output:-${input%/}_audio}
    mkdir -p "$output_dir"
    local input_dir output_abs count=0 failed=0
    input_dir=$(cd "$input" && pwd -P)
    output_abs=$(cd "$output_dir" && pwd -P)
    local -a child_opts=()
    if [[ -n "$aopt_bitrate" ]]; then child_opts+=(-b "$aopt_bitrate"); fi
    if (( aopt_size_active )); then child_opts+=(-s "$aopt_size"); fi
    if [[ -n "$aopt_acodec" ]]; then child_opts+=(--acodec "$aopt_acodec"); fi
    if [[ -n "$aopt_rate" ]]; then child_opts+=(--ar "$aopt_rate"); fi
    if [[ -n "$aopt_channels" ]]; then child_opts+=(--ac "$aopt_channels"); fi
    if (( aopt_force_copy )); then child_opts+=(--copy); fi

    local -a find_cmd=(find "$input_dir")
    if [[ "$output_abs" != "$input_dir" ]]; then
      find_cmd+=(-type d -path "$output_abs" -prune -o)
    fi
    find_cmd+=(-type f \( \
      -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mov' -o -iname '*.mkv' \
      -o -iname '*.webm' -o -iname '*.avi' -o -iname '*.wmv' -o -iname '*.asf' \
      -o -iname '*.flv' -o -iname '*.ts' -o -iname '*.m2ts' -o -iname '*.mpg' \
      -o -iname '*.mpeg' -o -iname '*.3gp' -o -iname '*.vob' \
      -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.flac' \
      -o -iname '*.wav' -o -iname '*.opus' -o -iname '*.ogg' -o -iname '*.oga' \
      -o -iname '*.wma' -o -iname '*.ac3' -o -iname '*.mka' -o -iname '*.aiff' \
      -o -iname '*.aif' \
    \) -print0)

    local relative stem rel_dir name destination
    while IFS= read -r -d '' file; do
      relative=${file#"$input_dir"/}
      stem=$(basename "${file%.*}")
      rel_dir=$(dirname "$relative")
      [[ "$rel_dir" == "." ]] && rel_dir=""
      mkdir -p "$output_abs/$rel_dir"
      name="${stem}.${af_ext}"
      if [[ -z "$rel_dir" ]]; then
        destination="$output_abs/$name"
      else
        destination="$output_abs/$rel_dir/$name"
      fi
      if [[ "$destination" == "$file" ]]; then
        destination="${destination%.*}_converted.${af_ext}"
      fi
      echo "处理: $file"
      local -a child_cmd=("$0" audio -i "$file" -f "$format" -o "$destination")
      if (( ${#child_opts[@]} > 0 )); then child_cmd+=("${child_opts[@]}"); fi
      if "${child_cmd[@]}"; then
        count=$(( count + 1 ))
      else
        echo "失败: $file" >&2
        failed=$(( failed + 1 ))
      fi
    done < <("${find_cmd[@]}")
    echo "音频批处理完成: 成功 $count 个，失败 $failed 个，输出目录: $output_dir"
    (( failed == 0 ))
    return
  fi

  [[ -f "$input" ]] || die "输入文件不存在: $input"

  # ---------- 输出路径 ----------
  local ext=$af_ext
  local in_dir in_stem default_name
  in_dir=$(dirname "$input")
  [[ "$in_dir" == "." ]] && in_dir=""
  in_stem=${input##*/}
  in_stem=${in_stem%.*}
  if [[ "${input##*.}" == "$ext" ]]; then
    default_name="${in_stem}_converted.${ext}"
  else
    default_name="${in_stem}.${ext}"
  fi

  if [[ -z "$output" ]]; then
    if [[ -z "$in_dir" ]]; then
      output=$default_name
    else
      output="$in_dir/$default_name"
    fi
  elif [[ "$output" == */ || -d "$output" ]]; then
    local dir_target=${output%/}
    if [[ -z "$dir_target" ]]; then
      output=$default_name
    else
      output="$dir_target/$default_name"
    fi
  else
    local out_dir="" out_name=$output
    if [[ "$output" == */* ]]; then
      out_dir=${output%/*}
      out_name=${output##*/}
    fi
    if [[ "$out_name" == *.* ]]; then
      out_name="${out_name%.*}.${ext}"
    else
      out_name="${out_name}.${ext}"
    fi
    if [[ -z "$out_dir" ]]; then
      output=$out_name
    else
      output="$out_dir/$out_name"
    fi
  fi
  local out_parent
  out_parent=$(dirname "$output")
  [[ -d "$out_parent" ]] || mkdir -p "$out_parent"

  audio_one "$input" "$output"
}

# 单文件音频提取/转换。依赖 do_audio 设置的 aopt_* / af_* 全局变量。
audio_one() {
  local input=$1 output=$2
  require_ffmpeg
  [[ -f "$input" ]] || die "输入文件不存在: $input"

  # ---------- 探测源 ----------
  local src_acodec src_sr src_ch src_abit src_duration src_bytes
  src_acodec=$(ffprobe_field "$input" a:0 codec_name)
  [[ -n "$src_acodec" ]] || die "输入没有音频流: $input"
  src_sr=$(ffprobe_field "$input" a:0 sample_rate)
  src_ch=$(ffprobe_field "$input" a:0 channels)
  src_abit=$(ffprobe_field "$input" a:0 bit_rate)
  src_duration=$(ffprobe_field "$input" "" duration)
  src_bytes=$(ffprobe_field "$input" "" size)

  local duration_ok
  duration_ok=$(awk -v d="$src_duration" 'BEGIN { print (d ~ /^[0-9]+([.][0-9]+)?$/ && d > 0) ? 1 : 0 }')
  if (( duration_ok == 0 )); then
    src_duration=$(ffprobe_field "$input" a:0 duration)
  fi
  [[ "$src_bytes" =~ ^[0-9]+$ ]] || src_bytes=$(stat -f%z "$input" 2>/dev/null || stat -c%s "$input" 2>/dev/null || echo 0)

  # ---------- 是否流复制 ----------
  local copy_audio=0 wants_encode=0 audio_enc=""
  if (( aopt_force_copy )); then
    if ! video_codec_allowed "$af_copy" "$src_acodec"; then
      die "音频 $src_acodec 不能直接放入 ${af_name} 容器；去掉 --copy 让脚本自动转码"
    fi
    copy_audio=1
  else
    if [[ -n "$aopt_acodec" || -n "$aopt_bitrate" || -n "$aopt_rate" || -n "$aopt_channels" ]]; then
      wants_encode=1
    fi
    if (( aopt_size_active )); then
      if (( src_bytes > 0 )) && (( aopt_target_bytes >= src_bytes )); then
        if (( ! wants_encode )) && video_codec_allowed "$af_copy" "$src_acodec"; then
          echo "提示: 目标大小 $(human_bytes "$aopt_target_bytes") 不小于源文件 $(human_bytes "$src_bytes")，直接流复制。" >&2
          copy_audio=1
        else
          echo "提示: 目标大小 $(human_bytes "$aopt_target_bytes") 不小于源文件 $(human_bytes "$src_bytes")，改用默认码率转码。" >&2
        fi
      else
        wants_encode=1
      fi
    fi
    if (( ! copy_audio )) && (( ! wants_encode )) && video_codec_allowed "$af_copy" "$src_acodec"; then
      copy_audio=1
    fi
  fi

  # ---------- 编码参数 ----------
  local -a a_args=()
  if (( copy_audio )); then
    a_args=(-c:a copy)
  else
    audio_enc=$af_enc
    if [[ -n "$aopt_acodec" ]]; then audio_enc=$aopt_acodec; fi
    case " $af_encs " in
      *" $audio_enc "*) ;;
      *) die "${af_name} 容器不支持音频编码: ${audio_enc}（可用: ${af_encs# }）" ;;
    esac

    # libvorbis 缺失时退回 libopus（ogg 容器两者都支持）。
    if [[ "$audio_enc" == libvorbis ]] && ! have_encoder libvorbis; then
      if have_encoder libopus; then
        echo "提示: 当前 ffmpeg 缺少 libvorbis，改用 libopus。" >&2
        audio_enc=libopus
      else
        die "当前 ffmpeg 缺少 libvorbis 与 libopus 编码器"
      fi
    fi
    have_encoder "$audio_enc" || die "当前 ffmpeg 缺少音频编码器: $audio_enc"

    local want_bit=""
    if [[ -n "$aopt_bitrate" ]]; then want_bit=$aopt_bitrate; fi

    if (( aopt_size_active )); then
      audio_codec_info "$audio_enc"
      if [[ "$ac_kind" == lossless ]]; then
        die "$audio_enc 为无损编码，不能用 -s 指定大小；请改用 -b 或换成有损格式"
      fi
      (( duration_ok )) || die "无法获取音频时长，不能用 -s 推算码率；请改用 -b"
      local calc
      calc=$(awk -v bytes="$aopt_target_bytes" -v dur="$src_duration" 'BEGIN { printf "%d", bytes * 8 / dur / 1000 * 0.97 }')
      if (( calc < 16 )); then
        die "目标大小 ${aopt_size} 太小（约 ${calc}kbps），请增大目标大小"
      fi
      want_bit="${calc}k"
    fi

    audio_build_encode "$audio_enc" "$want_bit" "$aopt_rate" "$aopt_channels" "$src_sr" "$src_ch"
    a_args=("${aa_args[@]}")
  fi

  # ---------- 封装与执行 ----------
  local -a mux_args=(-f "$af_muxer")
  if [[ "$af_faststart" == 1 ]]; then mux_args+=(-movflags +faststart); fi

  local -a cmd=(ffmpeg -hide_banner -nostdin -loglevel error -stats -y -i "$input")
  cmd+=(-map 0:a:0 -vn)
  cmd+=("${a_args[@]}")
  cmd+=(-map_metadata 0)
  cmd+=("${mux_args[@]}")
  cmd+=("$output")
  if ! "${cmd[@]}"; then
    die "音频转换失败: $input"
  fi
  [[ -f "$output" ]] || die "编码未生成输出文件: $output"

  # ---------- 结果报告 ----------
  local out_bytes audio_line
  out_bytes=$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output")
  if (( copy_audio )); then
    audio_line="${src_acodec} -> 流复制"
  else
    audio_line="${src_acodec} -> ${audio_enc}"
    if [[ "$aa_kind" == lossy ]]; then
      audio_line="$audio_line ${aa_bit}"
    else
      audio_line="$audio_line 无损"
    fi
    if (( aa_rate_changed )); then audio_line="$audio_line ${aa_rate}Hz"; fi
    if (( aa_ch_changed )); then audio_line="$audio_line ${aa_ch}ch"; fi
  fi

  printf '已生成: %s\n' "$output"
  printf '音频: %s\n' "$audio_line"
  printf '大小: %s -> %s' "$(human_bytes "$src_bytes")" "$(human_bytes "$out_bytes")"
  if [[ "$src_duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '，时长 %s' "$(human_duration "$src_duration")"
  fi
  printf '\n'

  if (( aopt_size_active )) && (( out_bytes > aopt_target_bytes * 11 / 10 )); then
    echo "提示: 实际大小超出目标 10% 以上；可改用有损编码或增大目标大小。" >&2
  fi
}

# ---------- info 子命令 ----------
info_usage() {
  cat <<'EOF'
用法:
  media.sh info -i FILE
  media.sh info FILE

查看媒体文件的基本信息，便于决定转换/压缩参数。
输出容器、大小、时长、总码率、轨道数量，以及视频编码/分辨率/帧率/像素格式/
码率、音频编码/采样率/声道/码率，并给出按比例压缩的 -s 参考值。

示例:
  media.sh info -i movie.mp4
  media.sh info movie.mp4
EOF
}

do_info() {
  local input=""
  if (( $# > 0 )) && [[ "$1" != -* ]]; then
    input=$1
    shift
  fi
  while (( $# > 0 )); do
    case "$1" in
      -i|--input) input=$2; shift 2 ;;
      -h|--help) info_usage; exit 0 ;;
      *) echo "未知参数: $1" >&2; info_usage; exit 2 ;;
    esac
  done
  [[ -n "$input" ]] || { echo "错误: 缺少 -i/--input" >&2; info_usage; exit 2; }
  require_ffmpeg
  [[ -f "$input" ]] || die "输入文件不存在: $input"

  local fmt duration size total_br
  local vcodec vprofile vw vh vfps vpix vbr vframes
  local acodec aprofile asr ach alayout abr
  fmt=$(ffprobe_field "$input" "" format_name)
  duration=$(ffprobe_field "$input" "" duration)
  size=$(ffprobe_field "$input" "" size)
  total_br=$(ffprobe_field "$input" "" bit_rate)

  vcodec=$(ffprobe_field "$input" v:0 codec_name)
  vprofile=$(ffprobe_field "$input" v:0 profile)
  vw=$(ffprobe_field "$input" v:0 width)
  vh=$(ffprobe_field "$input" v:0 height)
  vfps=$(ffprobe_field "$input" v:0 avg_frame_rate)
  vpix=$(ffprobe_field "$input" v:0 pix_fmt)
  vbr=$(ffprobe_field "$input" v:0 bit_rate)
  vframes=$(ffprobe_field "$input" v:0 nb_frames)

  acodec=$(ffprobe_field "$input" a:0 codec_name)
  aprofile=$(ffprobe_field "$input" a:0 profile)
  asr=$(ffprobe_field "$input" a:0 sample_rate)
  ach=$(ffprobe_field "$input" a:0 channels)
  alayout=$(ffprobe_field "$input" a:0 channel_layout)
  abr=$(ffprobe_field "$input" a:0 bit_rate)

  [[ "$size" =~ ^[0-9]+$ ]] || size=$(stat -f%z "$input" 2>/dev/null || stat -c%s "$input" 2>/dev/null || echo 0)
  if ! [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    duration=$(ffprobe_field "$input" v:0 duration)
  fi
  case "$vprofile" in unknown|N/A|n/a) vprofile="" ;; esac
  case "$aprofile" in unknown|N/A|n/a) aprofile="" ;; esac
  case "$alayout" in unknown|N/A|n/a) alayout="" ;; esac

  local vcount acount scount
  vcount=$(count_streams v "$input")
  acount=$(count_streams a "$input")
  scount=$(count_streams s "$input")

  # 部分容器（wmv/mkv/ts）不提供单流码率：只有在所有音频轨码率都已知时，
  # 才用“总码率 - 音频”反推视频码率，避免多音轨时给出误导值。
  local vbr_est=0 abr_est=0 audio_sum=0 audio_known=0
  if (( acount == 0 )); then
    audio_known=1
  else
    local a_numeric=0
    a_numeric=$(ffprobe -v error -select_streams a -show_entries stream=index,bit_rate -of csv=p=0 "$input" 2>/dev/null | sort -u | awk -F, '$2 ~ /^[0-9]+$/ { n++ } END { print n+0 }' || true)
    if (( a_numeric == acount )); then
      audio_known=1
      audio_sum=$(ffprobe -v error -select_streams a -show_entries stream=index,bit_rate -of csv=p=0 "$input" 2>/dev/null | sort -u | awk -F, '$2 ~ /^[0-9]+$/ { s += $2 } END { printf "%d", s }' || true)
    fi
  fi

  if [[ "$vbr" =~ ^[0-9]+$ ]] && (( vbr > 0 )); then
    :
  elif [[ "$total_br" =~ ^[0-9]+$ ]] && (( total_br > 0 )) && (( audio_known )); then
    vbr=$(( total_br - audio_sum ))
    (( vbr < 0 )) && vbr=0
    vbr_est=1
  fi
  if ! [[ "$abr" =~ ^[0-9]+$ ]] || (( abr == 0 )); then
    if (( acount == 1 )) && (( ! vbr_est )) && [[ "$vbr" =~ ^[0-9]+$ ]] \
       && [[ "$total_br" =~ ^[0-9]+$ ]] && (( total_br > vbr )); then
      abr=$(( total_br - vbr ))
      abr_est=1
    fi
  fi

  local container_disp=$fmt base_name=${input##*/}
  if [[ "$base_name" == *.* ]]; then
    container_disp=$(printf '%s' "${base_name##*.}" | tr '[:upper:]' '[:lower:]')
  fi
  printf '文件: %s\n' "$input"
  if [[ -n "$container_disp" ]]; then printf '容器: %s\n' "$container_disp"; fi
  printf '大小: %s（%s 字节）\n' "$(human_bytes "$size")" "$size"
  if [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '时长: %s\n' "$(human_duration "$duration")"
  else
    printf '时长: 未知\n'
  fi
  if [[ "$total_br" =~ ^[0-9]+$ ]] && (( total_br > 0 )); then
    printf '总码率: %s\n' "$(human_bitrate "$total_br")"
  fi
  printf '轨道: 视频 %s、音频 %s、字幕 %s\n' "$vcount" "$acount" "$scount"

  if [[ -n "$vcodec" ]]; then
    echo
    printf '视频:\n'
    if [[ -n "$vprofile" ]]; then
      printf '  编码: %s (%s)\n' "$vcodec" "$vprofile"
    else
      printf '  编码: %s\n' "$vcodec"
    fi
    if [[ "$vw" =~ ^[0-9]+$ && "$vh" =~ ^[0-9]+$ ]]; then
      printf '  分辨率: %sx%s\n' "$vw" "$vh"
    fi
    if [[ -n "$vfps" ]]; then
      printf '  帧率: %s fps\n' "$(fps_display "$vfps")"
    fi
    if [[ -n "$vpix" ]]; then printf '  像素格式: %s\n' "$vpix"; fi
    if [[ "$vbr" =~ ^[0-9]+$ ]] && (( vbr > 0 )); then
      if (( vbr_est )); then
        printf '  码率: ≈ %s（由总码率推算）\n' "$(human_bitrate "$vbr")"
      else
        printf '  码率: %s\n' "$(human_bitrate "$vbr")"
      fi
    fi
    if [[ "$vframes" =~ ^[0-9]+$ ]] && (( vframes > 0 )); then
      printf '  帧数: %s\n' "$vframes"
    fi
  else
    echo
    printf '视频: 无\n'
  fi

  if [[ -n "$acodec" ]]; then
    echo
    printf '音频:\n'
    if [[ -n "$aprofile" ]]; then
      printf '  编码: %s (%s)\n' "$acodec" "$aprofile"
    else
      printf '  编码: %s\n' "$acodec"
    fi
    if [[ "$asr" =~ ^[0-9]+$ ]]; then printf '  采样率: %s Hz\n' "$asr"; fi
    if [[ "$ach" =~ ^[0-9]+$ ]]; then
      if [[ -n "$alayout" ]]; then
        printf '  声道: %s (%s)\n' "$ach" "$alayout"
      else
        printf '  声道: %s\n' "$ach"
      fi
    fi
    if [[ "$abr" =~ ^[0-9]+$ ]] && (( abr > 0 )); then
      if (( abr_est )); then
        printf '  码率: ≈ %s（由总码率推算）\n' "$(human_bitrate "$abr")"
      else
        printf '  码率: %s\n' "$(human_bitrate "$abr")"
      fi
    elif (( acount > 1 )); then
      printf '  码率: 未知（多音轨，容器未写入单轨码率）\n'
    fi
  else
    echo
    printf '音频: 无\n'
  fi

  if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 1000 )); then
    echo
    printf '压缩参考: 80%%≈-s %s，50%%≈-s %s，30%%≈-s %s\n' \
      "$(size_arg $(( size * 80 / 100 )))" \
      "$(size_arg $(( size * 50 / 100 )))" \
      "$(size_arg $(( size * 30 / 100 )))"
  fi

  if (( acount > 1 )); then
    echo "提示: 含 $acount 条音频轨，video/audio 子命令只保留第 1 条。"
  fi
  if (( scount > 0 )); then
    echo "提示: 含 $scount 条字幕轨，video 转换不会保留字幕。"
  fi
  return 0
}

# ---------- 主入口 ----------
main() {
  (( $# > 0 )) || { echo "缺少子命令" >&2; echo "可用: convert, gif, video, audio, info" >&2; exit 2; }
  local sub=$1; shift
  case "$sub" in
    convert) do_convert "$@" ;;
    gif) do_gif "$@" ;;
    video) do_video "$@" ;;
    audio) do_audio "$@" ;;
    info) do_info "$@" ;;
    -h|--help|help) 
      echo "media.sh - 通用媒体转换工具"
      echo ""
      echo "用法: media.sh <子命令> [参数]"
      echo ""
      echo "子命令:"
      echo "  convert  图片格式转换与压缩"
      echo "  gif      视频转 GIF"
      echo "  video    视频格式转换与压缩"
      echo "  audio    音频提取与格式转换"
      echo "  info     查看媒体文件基本信息"
      echo ""
      echo "查看帮助: media.sh <子命令> --help"
      ;;
    *) echo "未知子命令: $sub" >&2; echo "可用: convert, gif, video, audio, info" >&2; exit 2 ;;
  esac
}

main "$@"