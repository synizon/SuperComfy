#!/usr/bin/env bash
# Durability mirror between the container disk (working copy) and the RunPod
# volume. Sourced by entrypoint.sh for volume_hydrate; run as a process for
# the background push loop:  volume-sync.sh LOCAL_ROOT VOLUME_ROOT [INTERVAL]
set -euo pipefail

# Mirrored both ways. Models are deliberately absent: the volume is ~35GB
# while models are hundreds of re-downloadable GB. Add comfy/models/loras via
# SUPERCOMFY_MIRROR_ITEMS (space-separated) if your LoRAs must survive pod loss.
if [ -n "${SUPERCOMFY_MIRROR_ITEMS:-}" ]; then
  read -ra MIRROR_ITEMS <<<"$SUPERCOMFY_MIRROR_ITEMS"
else
  MIRROR_ITEMS=(comfy/user comfy/output comfy/input comfy/custom_nodes .env)
fi

_sync_item() {
  local src="$1" dest="$2"
  [ -e "$src" ] || return 0
  if [ -d "$src" ]; then
    mkdir -p "$dest"
    # -au: never overwrite newer files, never delete; skip in-flight downloads.
    rsync -au --exclude '*.tmp' --exclude '*.tmp.*' "$src/" "$dest/"
  else
    mkdir -p "$(dirname "$dest")"
    rsync -au "$src" "$dest"
  fi
}

volume_hydrate() {
  local volume_root="$1" local_root="$2" item
  if [ ! -d "$volume_root" ]; then
    echo "volume-sync: nothing to hydrate at $volume_root (first run)"
    return 0
  fi
  for item in "${MIRROR_ITEMS[@]}"; do
    _sync_item "$volume_root/$item" "$local_root/$item"
  done
  echo "volume-sync: hydrated ${MIRROR_ITEMS[*]} from $volume_root"
}

volume_push() {
  local local_root="$1" volume_root="$2" item rc=0
  mkdir -p "$volume_root" || return 1
  for item in "${MIRROR_ITEMS[@]}"; do
    _sync_item "$local_root/$item" "$volume_root/$item" || rc=1
  done
  return "$rc"
}

volume_sync_loop() {
  local local_root="$1" volume_root="$2" interval="${3:-60}"
  while true; do
    [ -e "$local_root/.volume-sync-stop" ] && break
    # Background sleep + wait so TERM interrupts the pause immediately.
    sleep "$interval" &
    wait $! || true
    volume_push "$local_root" "$volume_root" \
      || echo "volume-sync: push failed — retrying in ${interval}s"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  LOCAL_ROOT="${1:?usage: volume-sync.sh LOCAL_ROOT VOLUME_ROOT [INTERVAL]}"
  VOLUME_ROOT="${2:?usage: volume-sync.sh LOCAL_ROOT VOLUME_ROOT [INTERVAL]}"
  INTERVAL="${3:-60}"
  _final_push() { volume_push "$LOCAL_ROOT" "$VOLUME_ROOT" || true; }
  trap _final_push EXIT
  trap 'exit 0' TERM INT
  volume_sync_loop "$LOCAL_ROOT" "$VOLUME_ROOT" "$INTERVAL"
fi
