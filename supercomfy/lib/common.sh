# Shared helpers for SuperComfy scripts. Source this file, don't execute it.

SUPERCOMFY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_DIR="$SUPERCOMFY_ROOT/cache"
VENV_DIR="$CACHE_DIR/venv"
VENV_PY="$VENV_DIR/bin/python"
COMFY_DIR="$SUPERCOMFY_ROOT/comfy"
CONSTRAINTS_FILE="$CACHE_DIR/constraints.txt"
LANE_FILE="$CACHE_DIR/torch-lane.env"
ENV_FILE="$SUPERCOMFY_ROOT/.env"
BIN_DIR="$CACHE_DIR/bin"

COMFYUI_REPO="https://github.com/Comfy-Org/ComfyUI"

if [ -t 1 ]; then
  C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
  C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_CYAN=$'\033[36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
fi

banner() { # banner "Installer"
  printf '%s' "$C_CYAN"
  cat <<'EOF'

  ███████╗██╗   ██╗██████╗ ███████╗██████╗  ██████╗ ██████╗ ███╗   ███╗███████╗██╗   ██╗
  ██╔════╝██║   ██║██╔══██╗██╔════╝██╔══██╗██╔════╝██╔═══██╗████╗ ████║██╔════╝╚██╗ ██╔╝
  ███████╗██║   ██║██████╔╝█████╗  ██████╔╝██║     ██║   ██║██╔████╔██║█████╗   ╚████╔╝
  ╚════██║██║   ██║██╔═══╝ ██╔══╝  ██╔══██╗██║     ██║   ██║██║╚██╔╝██║██╔══╝    ╚██╔╝
  ███████║╚██████╔╝██║     ███████╗██║  ██║╚██████╗╚██████╔╝██║ ╚═╝ ██║██║        ██║
  ╚══════╝ ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝        ╚═╝
EOF
  printf '%s' "$C_RESET"
  printf '  %sComfyUI for Linux & RunPod — CUDA 13.x%s' "$C_DIM" "$C_RESET"
  [ $# -gt 0 ] && printf '   %s[%s]%s' "$C_BOLD" "$1" "$C_RESET"
  printf '\n\n'
}

step() { printf '%s==>%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s⚠ %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
die()  { printf '  %s✘ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# Load .env — a value already in the OS environment always wins over the file.
load_env() {
  [ -f "$ENV_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}" val="${line#*=}"
    case "$key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    [ -z "${!key+x}" ] && export "$key=$val"
  done < "$ENV_FILE"
}

# save_env KEY VALUE — persist a simple (no-newline) value to .env.
save_env() {
  local key="$1" val="$2" tmp
  touch "$ENV_FILE" && chmod 600 "$ENV_FILE"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$ENV_FILE" && chmod 600 "$ENV_FILE"
}

port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

pick_port() { # pick_port BASE — echoes first free port in [BASE, BASE+20]
  local p="$1" limit=$(( $1 + 20 ))
  while [ "$p" -le "$limit" ]; do
    if port_free "$p"; then printf '%s' "$p"; return 0; fi
    p=$((p + 1))
  done
  return 1
}

ensure_uv() {
  if ! command -v uv >/dev/null 2>&1; then
    step "Installing uv (Python package manager)"
    curl -LsSf https://astral.sh/uv/install.sh | sh || die "uv install failed"
  fi
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null 2>&1 || die "uv not on PATH after install — open a new shell and retry"
}

# Abort unless the venv torch is a CUDA build (a node/dep can silently swap in the CPU wheel).
cuda_wheel_gate() {
  "$VENV_PY" -c 'import torch, sys; sys.exit(0 if torch.version.cuda else 1)' 2>/dev/null \
    || die "torch in $VENV_DIR is not a CUDA build. Re-run ./install.sh"
  ok "torch $("$VENV_PY" -c 'import torch; print(torch.__version__)') (CUDA $("$VENV_PY" -c 'import torch; print(torch.version.cuda)'))"
}

requirements_hash() { sha256sum "$COMFY_DIR/requirements.txt" | cut -d' ' -f1; }
