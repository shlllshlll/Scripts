#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  compress-image.sh INPUT TARGET_SIZE FORMAT [OUTPUT]
  compress-image.sh INPUT_DIR TARGET_SIZE FORMAT [OUTPUT_DIR]

示例:
  compress-image.sh photo.jpg 200K avif
  compress-image.sh page.png 1M jpg compressed.jpg
  compress-image.sh ./images 200K avif ./converted

FORMAT 支持: jpg/jpeg, avif, webp
          heif/heic（HEVC/H.265，需要 libheif 的 heif-enc）
TARGET_SIZE 支持: B, K/KB, M/MB（例如 200K、1.5M）

当 INPUT_DIR 是文件夹时，脚本会递归查找常见图片（jpg、jpeg、png、webp、heic、heif、avif），
按同一目标大小和格式逐张转换。输出目录默认为 INPUT_DIR_compressed；源文件不会被覆盖。

依赖:
  ffmpeg 和 ffprobe（必需）；heif/heic 另需 heif-enc。
  macOS: brew install ffmpeg libheif
         若 Homebrew 升级后 ffmpeg 报缺少动态库：brew reinstall ffmpeg x265
  Debian/Ubuntu: sudo apt install ffmpeg libheif-examples
  Fedora: sudo dnf install ffmpeg libheif-tools
EOF
}

die() { echo "错误: $*" >&2; exit 1; }

if [[ $# -eq 0 || ${1:-} == "-h" || ${1:-} == "--help" ]]; then usage; exit 0; fi
[[ $# -ge 3 && $# -le 4 ]] || { usage; exit 2; }
input=$1
target_text=$2
format=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
output=${4:-}

case "$format" in
  jpg|jpeg) batch_ext=jpg ;;
  avif|webp|heif|heic) batch_ext=$format ;;
  *) die "不支持的格式: ${format}（可用 jpg、avif、webp、heif、heic）" ;;
esac

# Directory mode delegates each file to the single-file path below, keeping
# the quality/size search identical for both modes.
if [[ -d "$input" ]]; then
  output_dir=${output:-${input%/}_compressed}
  mkdir -p "$output_dir"
  input_dir=$(cd "$input" && pwd -P)
  output_dir=$(cd "$output_dir" && pwd -P)
  count=0
  failed=0
  while IFS= read -r -d '' file; do
    relative=${file#"$input_dir"/}
    filename=$(basename "$relative")
    stem=${filename%.*}
    destination_dir="$output_dir/$(dirname "$relative")"
    mkdir -p "$destination_dir"
    destination="$destination_dir/${stem}.${batch_ext}"
    echo "处理: $file"
    if "$0" "$file" "$target_text" "$format" "$destination"; then
      count=$((count + 1))
    else
      echo "失败: $file" >&2
      failed=$((failed + 1))
    fi
  done < <(find "$input_dir" -type d -path "$output_dir" -prune -o -type f \( \
    -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \
    -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.avif' \
  \) -print0)
  echo "批处理完成: 成功 $count 张，失败 $failed 张，输出目录: $output_dir"
  if (( failed > 0 )); then
    exit 1
  fi
  exit 0
fi

[[ -f "$input" ]] || die "输入文件不存在: $input"
if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null || ! ffmpeg -version >/dev/null 2>&1 || ! ffprobe -version >/dev/null 2>&1; then
  echo "错误: ffmpeg 或 ffprobe 未安装，或当前无法正常运行。" >&2
  case "$(uname -s)" in
    Darwin) echo "macOS 安装: brew install ffmpeg；若已安装但报动态库缺失：brew reinstall ffmpeg x265" >&2 ;;
    Linux) echo "Linux 安装示例: sudo apt install ffmpeg（Debian/Ubuntu）或 sudo dnf install ffmpeg（Fedora）" >&2 ;;
    *) echo "请使用系统包管理器安装 ffmpeg。" >&2 ;;
  esac
  exit 1
fi

# Convert a human-readable size to bytes without requiring external packages.
if [[ "$target_text" =~ ^([0-9]+([.][0-9]+)?)([Kk][Bb]?|[Mm][Bb]?|[Bb])?$ ]]; then
  number=${BASH_REMATCH[1]}
  unit=${BASH_REMATCH[3]:-B}
else
  die "目标大小格式无效: $target_text"
fi
case "$(printf '%s' "$unit" | tr '[:lower:]' '[:upper:]')" in
  B)  multiplier=1 ;;
  K|KB) multiplier=1024 ;;
  M|MB) multiplier=$((1024 * 1024)) ;;
  *) die "不支持的大小单位: $unit" ;;
esac
target_bytes=$(awk -v n="$number" -v m="$multiplier" 'BEGIN { printf "%d", n*m }')
(( target_bytes > 0 )) || die "目标大小必须大于 0"

case "$format" in
  jpg|jpeg)
    ext=jpg
    codec_args=(-c:v mjpeg -pix_fmt yuvj444p)
    # JPEG: lower q:v means better quality. Search 2..31.
    quality_low=2; quality_high=31
    ;;
  avif)
    ext=avif
    command -v ffmpeg >/dev/null
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libsvtav1' || die "当前 ffmpeg 没有 libsvtav1 AV1 编码器"
    codec_args=(-c:v libsvtav1 -pix_fmt yuv420p -preset 6 -svtav1-params verbosity=0 -f avif)
    # AV1: lower CRF means better quality. Search 0..63.
    quality_low=0; quality_high=63
    ;;
  webp)
    ext=webp
    codec_args=(-c:v libwebp -pix_fmt yuv420p)
    # libwebp q:v: higher means better quality. Search 0..100.
    quality_low=0; quality_high=100
    ;;
  heif|heic)
    if [[ "$format" == heif ]]; then ext=heif; else ext=heic; fi
    if ! command -v heif-enc >/dev/null; then
      echo "错误: 未找到 heif-enc（libheif）。" >&2
      case "$(uname -s)" in
        Darwin) echo "macOS 安装: brew install libheif" >&2 ;;
        Linux) echo "Linux 安装示例: sudo apt install libheif-examples（Debian/Ubuntu）或 sudo dnf install libheif-tools（Fedora）" >&2 ;;
        *) echo "请使用系统包管理器安装 libheif 及 heif-enc。" >&2 ;;
      esac
      exit 1
    fi
    quality_low=0; quality_high=100
    ;;
  *) die "不支持的格式: ${format}（可用 jpg、avif、webp、heif、heic）" ;;
esac

if [[ -z "$output" ]]; then
  stem=${input%.*}
  output="${stem}_compressed.${ext}"
else
  # Ensure the selected container matches the requested format.
  output="${output%.*}.${ext}"
fi

width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$input")
height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input")
[[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]] || die "无法读取图片尺寸"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
best="$tmpdir/best.$ext"
best_bytes=0
best_width=0
best_quality=0

encode() {
  local w=$1 q=$2 dst=$3
  local scale_filter="scale='min(${w},iw)':-2:flags=lanczos"
  local rate_args
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
  if [[ "$format" == avif ]]; then
    rate_args=(-crf "$q")
  else
    rate_args=(-q:v "$q")
  fi
  if ! ffmpeg -hide_banner -loglevel error -y -i "$input" -vf "$scale_filter" \
    "${codec_args[@]}" "${rate_args[@]}" "$dst" 2>"$tmpdir/ffmpeg.err"; then
    cat "$tmpdir/ffmpeg.err" >&2
    return 1
  fi
}

# Try larger widths first. For each width, binary-search the best quality that fits.
for candidate_width in "$width" 2400 2200 2000 1800 1600 1400 1200 1000 800 600; do
  (( candidate_width > width )) && continue
  low=$quality_low
  high=$quality_high
  fit_quality=-1
  while (( low <= high )); do
    mid=$(( (low + high) / 2 ))
    candidate="$tmpdir/candidate.$ext"
    encode "$candidate_width" "$mid" "$candidate"
    bytes=$(stat -f%z "$candidate" 2>/dev/null || stat -c%s "$candidate")
    if (( bytes <= target_bytes )); then
      fit_quality=$mid
      # Better quality is lower q for JPG/AVIF, higher q for WebP.
      if [[ "$format" == webp ]]; then low=$((mid + 1)); else high=$((mid - 1)); fi
    else
      if [[ "$format" == webp ]]; then high=$((mid - 1)); else low=$((mid + 1)); fi
    fi
  done
  (( fit_quality >= 0 )) || continue
  encode "$candidate_width" "$fit_quality" "$candidate"
  bytes=$(stat -f%z "$candidate" 2>/dev/null || stat -c%s "$candidate")
  # Prefer the largest readable dimensions, then the highest quality.
  if (( candidate_width > best_width )) || \
     (( candidate_width == best_width && bytes > best_bytes )); then
    # NAS/SMB volumes may reject macOS extended attributes even when the
    # image content itself was written successfully.
    if ! cp -X "$candidate" "$best" 2>/dev/null; then
      cp "$candidate" "$best"
    fi
    best_width=$candidate_width
    best_quality=$fit_quality
    best_bytes=$bytes
  fi
done

(( best_width > 0 )) || die "无法在目标大小内生成文件，请增大目标大小"
if ! cp -X "$best" "$output" 2>/dev/null; then
  cp "$best" "$output"
fi
printf '已生成: %s\n尺寸: %sx%s -> 宽度 %s\n大小: %s bytes (目标 <= %s bytes)\n质量参数: %s\n' \
  "$output" "$width" "$height" "$best_width" "$best_bytes" "$target_bytes" "$best_quality"
