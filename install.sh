#!/usr/bin/env bash
# SuperComfy installer: Python 3.13 venv (uv), CUDA-routed torch, latest ComfyUI
# release, dependency constraints, and the optional comfy-kitchen accelerator.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=supercomfy/lib/common.sh
source "$SCRIPT_DIR/supercomfy/lib/common.sh"
# shellcheck source=supercomfy/lib/cuda.sh
source "$SCRIPT_DIR/supercomfy/lib/cuda.sh"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "Usage: ./install.sh [--dry-run]"
      echo "  --dry-run   detect CUDA, print the torch wheel lane, change nothing"
      exit 0 ;;
    *) die "Unknown option: $arg (try --help)" ;;
  esac
done

banner "Installer"
load_env

step "Detecting CUDA"
route_torch_lane
ok "CUDA $CUDA_DETECTED -> $CU_TAG wheels ($TORCH_INDEX)"
ok "torch==$TORCH_PIN torchvision==$TORCHVISION_PIN torchaudio==${TORCHAUDIO_PIN:-latest}"

if [ "$DRY_RUN" -eq 1 ]; then
  ok "Dry run — nothing installed"
  exit 0
fi

need_cmd git
need_cmd curl
ensure_uv
mkdir -p "$CACHE_DIR"

step "Preparing Python 3.13 venv"
if [ -d "$VENV_DIR" ]; then
  # Refuse to touch a venv with running processes (a live ComfyUI would corrupt).
  if command -v lsof >/dev/null 2>&1 && [ -n "$(lsof -t +D "$VENV_DIR" 2>/dev/null | head -1)" ]; then
    die "Processes are running from $VENV_DIR — stop ComfyUI/Jupyter first"
  fi
  # A crashed pip/uv leaves ~-prefixed corpse dirs that break future installs.
  if [ -n "$(find "$VENV_DIR" -maxdepth 4 -path '*/site-packages/~*' -print -quit 2>/dev/null)" ]; then
    warn "Found a broken previous install in the venv — rebuilding it"
    rm -rf "$VENV_DIR"
  fi
fi
if [ ! -x "$VENV_PY" ]; then
  # Explicit install: uv configured with python-downloads=manual won't fetch on demand.
  uv python install 3.13 || die "Could not install Python 3.13 (uv python install failed)"
  uv venv --python 3.13 "$VENV_DIR" || die "Could not create the venv (uv venv failed)"
fi
ok "venv: $VENV_DIR"

step "Installing PyTorch ($CU_TAG)"
torch_spec="torch==$TORCH_PIN torchvision==$TORCHVISION_PIN"
[ -n "$TORCHAUDIO_PIN" ] && torch_spec="$torch_spec torchaudio==$TORCHAUDIO_PIN" || torch_spec="$torch_spec torchaudio"
have_torch="$("$VENV_PY" -c 'import torch; print(torch.__version__.split("+")[0])' 2>/dev/null || true)"
if [ "$have_torch" = "$TORCH_PIN" ]; then
  ok "torch $TORCH_PIN already installed"
else
  # shellcheck disable=SC2086  # torch_spec is a deliberate word-split list
  uv pip install --python "$VENV_PY" --index-url "$TORCH_INDEX" $torch_spec \
    || die "torch install failed"
fi
cuda_wheel_gate

write_constraints() {
  # Pin the packages custom-node requirements most often clobber.
  uv pip freeze --python "$VENV_PY" \
    | grep -E '^(torch|torchvision|torchaudio|numpy)==' > "$CONSTRAINTS_FILE" || true
}
write_constraints
save_torch_lane

step "Fetching ComfyUI (latest release)"
if [ ! -d "$COMFY_DIR/.git" ]; then
  git clone --filter=blob:none "$COMFYUI_REPO" "$COMFY_DIR" || die "ComfyUI clone failed"
fi
git -C "$COMFY_DIR" fetch --tags --quiet
latest_tag="$(git -C "$COMFY_DIR" tag --sort=-version:refname | grep -E '^v[0-9]' | head -1)"
[ -n "$latest_tag" ] || die "No release tag found in the ComfyUI repo"
git -C "$COMFY_DIR" -c advice.detachedHead=false checkout --quiet "$latest_tag"
ok "ComfyUI $latest_tag"

step "Installing ComfyUI requirements"
uv pip install --python "$VENV_PY" -r "$COMFY_DIR/requirements.txt" \
  -c "$CONSTRAINTS_FILE" --extra-index-url "$TORCH_INDEX" \
  || die "ComfyUI requirements install failed"
write_constraints
cuda_wheel_gate

step "Installing the dashboard (FastAPI)"
if uv pip install --python "$VENV_PY" -c "$CONSTRAINTS_FILE" \
    fastapi uvicorn python-multipart >/dev/null 2>&1; then
  ok "dashboard dependencies installed"
else
  warn "Dashboard install failed — run.sh will start ComfyUI without it"
fi

step "Installing comfy-kitchen (optional, best effort)"
if uv pip install --python "$VENV_PY" -c "$CONSTRAINTS_FILE" comfy-kitchen >/dev/null 2>&1; then
  ok "comfy-kitchen installed"
else
  warn "comfy-kitchen install failed — the comfy-kitchen selector option will be unavailable"
fi

if [ "${SUPERCOMFY_JUPYTER:-0}" = "1" ]; then
  step "Installing JupyterLab"
  uv pip install --python "$VENV_PY" -c "$CONSTRAINTS_FILE" jupyterlab \
    && ok "JupyterLab installed" || warn "JupyterLab install failed"
fi

cuda_wheel_gate
requirements_hash > "$VENV_DIR/.installed"
[ -f "$ENV_FILE" ] || cp "$SCRIPT_DIR/.env.example" "$ENV_FILE" 2>/dev/null || true

# Desktop launcher, so run.sh starts from the app menu (no terminal needed).
# Skipped on headless machines (RunPod pods, SSH sessions without a display).
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ -z "${RUNPOD_POD_ID:-}" ]; then
  app_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  mkdir -p "$app_dir"
  cat > "$app_dir/supercomfy.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=SuperComfy
Comment=Start ComfyUI (dashboard at http://localhost:8080)
Exec=$SUPERCOMFY_ROOT/run.sh
Path=$SUPERCOMFY_ROOT
Terminal=true
Icon=applications-graphics
Categories=Graphics;
EOF
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$app_dir" 2>/dev/null || true
  ok "App-menu launcher created — search for ${C_BOLD}SuperComfy${C_RESET} in your applications"
fi

printf '\n'
ok "SuperComfy is installed — start it with ${C_BOLD}./run.sh${C_RESET}"
