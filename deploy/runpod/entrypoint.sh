#!/usr/bin/env bash
# SuperComfy RunPod entrypoint: hydrate durable state from the volume, move
# ComfyUI to the latest release, then hand off to run.sh (dashboard + Caddy
# auth + JupyterLab). Stays PID 1 so it can flush the volume mirror on exit.
set -euo pipefail

ROOT=/opt/supercomfy
VOLUME_DIR="${SUPERCOMFY_VOLUME_DIR:-/persistent}"
VOLUME_ROOT="$VOLUME_DIR/supercomfy"
cd "$ROOT"

source "$ROOT/supercomfy/lib/common.sh"
load_env

# Models and the venv live on the container disk (the volume is a small
# durability mirror) — warn early when the disk looks too small for models.
free_kb="$(df -Pk "$ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if [ -n "$free_kb" ] && [ "$((free_kb / 1024 / 1024))" -lt "${SUPERCOMFY_MIN_FREE_GB:-100}" ]; then
  warn "Only $((free_kb / 1024 / 1024))GB free on the container disk — large models need more. Recreate the pod with a bigger container disk if downloads fail."
fi

MIRROR_MODE=""
if [ -d "$VOLUME_DIR" ] && [ "$(readlink -f "$VOLUME_DIR")" != "$(readlink -f "$ROOT")" ]; then
  MIRROR_MODE=1
  source "$ROOT/deploy/runpod/volume-sync.sh"
  volume_hydrate "$VOLUME_ROOT" "$ROOT"
  load_env # a hydrated .env may add COMFY_AUTH and friends
else
  echo "No volume at $VOLUME_DIR — outputs live on the container disk only."
fi

./update.sh || warn "Update failed — running the ComfyUI release baked into the image."

if [ "${PRELOAD_NODES:-0}" = "1" ]; then
  ./downloadnodes.sh --all || warn "Some custom nodes failed — re-run ./downloadnodes.sh from a terminal."
fi

# Image defaults: SageAttention preset (compiled in), JupyterLab on.
export COMFY_ATTENTION="${COMFY_ATTENTION:-sage}"
export JUPYTER_ENABLE="${JUPYTER_ENABLE:-1}"

if [ -z "${COMFY_AUTH:-}" ] && [ "${SUPERCOMFY_INSECURE:-0}" != "1" ]; then
  warn "COMFY_AUTH is not set — refusing to expose ComfyUI without a password."
  echo "Set COMFY_AUTH (pod template env) and restart, or set SUPERCOMFY_INSECURE=1 to run open."
  echo "Idling so you can fix this from the RunPod web terminal (set COMFY_AUTH in $ROOT/.env, then ./run.sh)."
  exec tail -f /dev/null
fi

if [ -z "$MIRROR_MODE" ]; then
  exec ./run.sh
fi

rm -f "$ROOT/.volume-sync-stop"
bash "$ROOT/deploy/runpod/volume-sync.sh" "$ROOT" "$VOLUME_ROOT" "${SUPERCOMFY_SYNC_INTERVAL:-60}" &
SYNC_PID=$!

APP_PID=""
_forward_term() {
  trap - TERM INT
  [ -n "$APP_PID" ] && kill -TERM "$APP_PID" 2>/dev/null || true
}
trap _forward_term TERM INT

./run.sh &
APP_PID=$!
set +e
wait "$APP_PID"
APP_EXIT=$?
if kill -0 "$APP_PID" 2>/dev/null; then # first wait was interrupted by a signal
  wait "$APP_PID"
  APP_EXIT=$?
fi
set -e

touch "$ROOT/.volume-sync-stop"
kill -TERM "$SYNC_PID" 2>/dev/null || true
set +e
wait "$SYNC_PID"
set -e
exit "$APP_EXIT"
