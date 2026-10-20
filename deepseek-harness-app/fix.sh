#!/usr/bin/env bash
#
# Fix the DeepSeek Harness App (native macOS GUI) starting `dsh` through Node.
#
# The app resolves `dsh` from the login shell's PATH and then runs:
#     node <path-to-dsh>
# pnpm/npm install `dsh` as a POSIX /bin/sh shim, which Node cannot parse.
# This installer puts a real JS launcher in ~/.dsh/app-bin and makes the app's
# login-shell probe prefer it, without changing `dsh` in ordinary terminals.
#
# It also installs the dsh CLI version the app expects. pnpm's default
# isolated layout cannot resolve dsh 0.2.x's native addon, so the pnpm install
# uses node-linker=hoisted.
#
# Usage:
#   ./fix.sh [--version 0.2.1-rc.2] [--restart]
#
# The script is idempotent: rerun it after upgrading dsh or changing machines.

set -euo pipefail

APP_BUNDLE_ID="ai.deepseek.DeepSeekHarnessApp"
APP_PATH="/Applications/DeepSeek Harness App.app"
DEFAULT_DSH_VERSION="0.2.1-rc.2"
DSH_VERSION="${DSH_VERSION:-$DEFAULT_DSH_VERSION}"
RESTART=0

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
WRAPPER_SRC="$SCRIPT_DIR/dsh-app-wrapper"
WRAPPER_DIR="$HOME/.dsh/app-bin"
WRAPPER="$WRAPPER_DIR/dsh"

MARK_BEGIN="# >>> deepseek-harness-app shim >>>"
MARK_END="# <<< deepseek-harness-app shim <<<"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --version <version>  dsh version to install (default: $DEFAULT_DSH_VERSION)
  --restart            restart DeepSeek Harness App after installing
  -h, --help           show this help

Environment:
  DSH_VERSION          same as --version
EOF
}

while (($# > 0)); do
  case "$1" in
    --version)
      (($# >= 2)) || die "--version needs a value"
      DSH_VERSION="$2"
      shift 2
      ;;
    --restart)
      RESTART=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "this patch is for macOS only"
[[ -f "$WRAPPER_SRC" ]] || die "missing $WRAPPER_SRC"
command -v node >/dev/null 2>&1 || die "Node.js is required (22.19+ or 24+)"
node -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major > 22 || (major === 22 && minor >= 19) ? 0 : 1)' \
  || die "Node.js 22.19+ is required; found $(node -v)"

if [[ -d "$APP_PATH" ]]; then
  info "found $APP_PATH"
else
  warn "$APP_PATH was not found; installing the launcher anyway"
fi

# --- 1. install a working dsh -------------------------------------------------
if command -v pnpm >/dev/null 2>&1; then
  info "installing @deepseek-ai/dsh@$DSH_VERSION with pnpm (hoisted linker)"
  pnpm add -g "@deepseek-ai/dsh@$DSH_VERSION" --config.node-linker=hoisted
elif command -v npm >/dev/null 2>&1; then
  info "pnpm not found; installing @deepseek-ai/dsh@$DSH_VERSION with npm"
  npm install -g "@deepseek-ai/dsh@$DSH_VERSION" --no-audit --no-fund
else
  die "pnpm or npm is required"
fi

# --- 2. install the JS launcher ----------------------------------------------
mkdir -p "$WRAPPER_DIR"
if [[ -f "$WRAPPER" ]] && ! cmp -s "$WRAPPER_SRC" "$WRAPPER"; then
  backup="$WRAPPER.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p "$WRAPPER" "$backup"
  info "backed up existing launcher to $backup"
fi
install -m 755 "$WRAPPER_SRC" "$WRAPPER"
info "installed launcher: $WRAPPER"

"$WRAPPER" -V >/dev/null 2>&1 || die "the launcher could not run dsh; check: node $WRAPPER -V"
info "launcher reports dsh $("$WRAPPER" -V 2>/dev/null)"

# --- 3. teach the app's login shell to prefer the launcher -------------------
pick_rc() {
  case "$(basename "${SHELL:-/bin/zsh}")" in
    zsh) printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) printf '%s\n' "$HOME/.bash_profile" ;;
    *) printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
  esac
}

RC_FILE=$(pick_rc)
[[ -f "$RC_FILE" ]] || { touch "$RC_FILE"; chmod 644 "$RC_FILE"; }

append_shim_block() {
  cat <<'EOF'
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
EOF
}

if grep -qF "$MARK_BEGIN" "$RC_FILE"; then
  info "updating the existing block in $RC_FILE"
elif grep -qF "$HOME/.dsh/app-bin" "$RC_FILE"; then
  warn "found an existing ~/.dsh/app-bin entry without markers; adding a marked block (duplicate PATH entries are harmless)"
fi

backup="$RC_FILE.bak.$(date +%Y%m%d-%H%M%S)"
cp -p "$RC_FILE" "$backup"
info "backed up $RC_FILE to $backup"

tmp=$(mktemp "${RC_FILE}.tmp.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cp -p "$RC_FILE" "$tmp"
awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
  $0 == begin { skip = 1; next }
  $0 == end   { skip = 0; next }
  !skip       { print }
' "$RC_FILE" > "$tmp"
printf '\n' >> "$tmp"
append_shim_block >> "$tmp"
printf '\n' >> "$tmp"
mv "$tmp" "$RC_FILE"
trap - EXIT
info "patched $RC_FILE"

# --- 4. verify ---------------------------------------------------------------
printf '\n'
printf '  launcher : %s (%s)\n' "$WRAPPER" "$("$WRAPPER" -V 2>/dev/null)"
printf '  terminal : %s (%s)\n' "$(command -v dsh 2>/dev/null || echo 'not found')" "$(dsh -V 2>/dev/null || echo 'n/a')"
APP_PROBE=$(env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL="${SHELL:-/bin/zsh}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm-256color __CFBundleIdentifier="$APP_BUNDLE_ID" "${SHELL:-/bin/zsh}" -ilc 'printf "\n__DSH_PATH__%s\n" "$(command -v dsh)"' 2>/dev/null | sed -n 's/.*__DSH_PATH__//p' | tail -n 1)
printf '  app probe: %s\n' "${APP_PROBE:-unknown}"
printf '\n'
info "done; restart DeepSeek Harness App to apply"

if ((RESTART)); then
  info "restarting DeepSeek Harness App"
  pkill -TERM -f "DeepSeekHarnessApp.app/Contents/MacOS/DeepSeekHarnessApp" 2>/dev/null || true
  sleep 2
  open -a "$APP_PATH"
fi
