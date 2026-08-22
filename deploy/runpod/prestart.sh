#!/usr/bin/env bash
# RunPod prestart: run.sh invokes this (via COMFY_PRESTART) after Caddy, the
# dashboard, and JupyterLab are up but before ComfyUI starts, so the pod's
# ports are live while the slow update + node preload run.
set -euo pipefail

ROOT=/opt/supercomfy
cd "$ROOT"
source "$ROOT/supercomfy/lib/common.sh"

./update.sh || warn "Update failed — running the ComfyUI release baked into the image."

if [ "${PRELOAD_NODES:-0}" = "1" ]; then
  ./downloadnodes.sh --all || warn "Some custom nodes failed — re-run ./downloadnodes.sh from a terminal."
fi
