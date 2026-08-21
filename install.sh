#!/usr/bin/env bash
# SuperComfy installer: Python 3.13 venv (uv), CUDA-routed torch, latest ComfyUI
# release, dependency constraints, and optional attention accelerators.
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

step "Installing attention accelerators (optional, best effort)"
if uv pip install --python "$VENV_PY" -c "$CONSTRAINTS_FILE" comfy-kitchen >/dev/null 2>&1; then
  ok "comfy-kitchen installed"
else
  warn "comfy-kitchen install failed — the comfy-kitchen selector option will be unavailable"
fi

# flash-attn: no official cu13 wheels; use mjun0812's prebuilt index if one
# matches this exact cu-tag + torch minor + python version.
flash_wheel="$("$VENV_PY" - "$CU_TAG" "$TORCH_PIN" <<'PYEOF' 2>/dev/null || true
import json, sys, urllib.request
cu, torch_pin = sys.argv[1], sys.argv[2]
torch_minor = ".".join(torch_pin.split(".")[:2])
cp = f"cp{sys.version_info.major}{sys.version_info.minor}"
req = urllib.request.Request(
    "https://api.github.com/repos/mjun0812/flash-attention-prebuild-wheels/releases?per_page=10",
    headers={"User-Agent": "supercomfy"})
for rel in json.load(urllib.request.urlopen(req, timeout=20)):
    for a in rel.get("assets", []):
        n = a["name"]
        if cu in n and f"torch{torch_minor}" in n and cp in n and "linux_x86_64" in n:
            print(a["browser_download_url"]); sys.exit()
PYEOF
)"
if [ -n "$flash_wheel" ]; then
  if uv pip install --python "$VENV_PY" -c "$CONSTRAINTS_FILE" "$flash_wheel" >/dev/null 2>&1; then
    ok "flash-attn installed ($(basename "$flash_wheel"))"
  else
    warn "flash-attn wheel failed to install — flash selector option will be unavailable"
  fi
else
  warn "No prebuilt flash-attn wheel for $CU_TAG/torch $TORCH_PIN — skipping (not required)"
fi

# SageAttention 2.2.0 must be compiled (PyPI's package is a stale 1.x). Needs nvcc.
if [ "${SUPERCOMFY_SAGE:-1}" = "1" ] && command -v nvcc >/dev/null 2>&1; then
  step "Building SageAttention 2.2.0 from source (this takes a few minutes)"
  arch="$("$VENV_PY" -c 'import torch; c=torch.cuda.get_device_capability(); print(f"{c[0]}.{c[1]}")' 2>/dev/null || true)"
  if [ -n "$arch" ] && TORCH_CUDA_ARCH_LIST="$arch" uv pip install --python "$VENV_PY" \
      -c "$CONSTRAINTS_FILE" --no-build-isolation \
      "git+https://github.com/thu-ml/SageAttention.git@v2.2.0"; then
    ok "SageAttention built for sm_${arch/./}"
  else
    warn "SageAttention build failed — sage selector option will be unavailable"
  fi
else
  warn "Skipping SageAttention (needs nvcc; set SUPERCOMFY_SAGE=1 and install cuda-toolkit to build it)"
fi

if [ "${SUPERCOMFY_JUPYTER:-0}" = "1" ]; then
  step "Installing JupyterLab"
  uv pip install --python "$VENV_PY" -c "$CONSTRAINTS_FILE" jupyterlab \
    && ok "JupyterLab installed" || warn "JupyterLab install failed"
fi

cuda_wheel_gate
requirements_hash > "$VENV_DIR/.installed"
[ -f "$ENV_FILE" ] || cp "$SCRIPT_DIR/.env.example" "$ENV_FILE" 2>/dev/null || true

printf '\n'
ok "SuperComfy is installed — start it with ${C_BOLD}./run.sh${C_RESET}"
