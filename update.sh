#!/usr/bin/env bash
# SuperComfy updater: pull the latest SuperComfy scripts, move ComfyUI to its
# newest release tag, and refresh requirements under the torch constraints.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=supercomfy/lib/common.sh
source "$SCRIPT_DIR/supercomfy/lib/common.sh"

COMFY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --comfy-only) COMFY_ONLY=1 ;;
    -h|--help)
      echo "Usage: ./update.sh [--comfy-only]"
      echo "  --comfy-only   update ComfyUI code only, skip dependency refresh"
      exit 0 ;;
    *) die "Unknown option: $arg (try --help)" ;;
  esac
done

banner "Updater"
load_env
need_cmd git
[ -x "$VENV_PY" ] && [ -d "$COMFY_DIR/.git" ] || die "SuperComfy is not installed yet — run ./install.sh first"

step "Updating SuperComfy scripts"
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$SCRIPT_DIR" pull --ff-only || warn "Could not fast-forward SuperComfy (local changes?) — continuing"
else
  warn "SuperComfy itself is not a git checkout — skipping self-update"
fi

step "Updating ComfyUI to the latest release"
git -C "$COMFY_DIR" fetch --tags --quiet
latest_tag="$(git -C "$COMFY_DIR" tag --sort=-version:refname | grep -E '^v[0-9]' | head -1)"
[ -n "$latest_tag" ] || die "No release tag found in the ComfyUI repo"
current="$(git -C "$COMFY_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)"
if [ "$current" = "$latest_tag" ]; then
  ok "ComfyUI already at $latest_tag"
else
  git -C "$COMFY_DIR" -c advice.detachedHead=false checkout --quiet "$latest_tag"
  ok "ComfyUI $current -> $latest_tag"
fi

if [ "$COMFY_ONLY" -eq 0 ]; then
  step "Refreshing ComfyUI requirements (torch pinned by constraints)"
  ensure_uv
  [ -f "$CONSTRAINTS_FILE" ] || die "Missing $CONSTRAINTS_FILE — run ./install.sh"
  [ -f "$LANE_FILE" ] || die "Missing $LANE_FILE — run ./install.sh"
  # shellcheck source=/dev/null
  source "$LANE_FILE"
  uv pip install --python "$VENV_PY" -r "$COMFY_DIR/requirements.txt" \
    -c "$CONSTRAINTS_FILE" --extra-index-url "$TORCH_INDEX" \
    || die "Requirements refresh failed"
  cuda_wheel_gate
  requirements_hash > "$VENV_DIR/.installed"
fi

printf '\n'
ok "Update complete — start ComfyUI with ${C_BOLD}./run.sh${C_RESET}"
