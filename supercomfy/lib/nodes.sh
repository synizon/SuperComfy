# Custom-node install helpers. Source after common.sh.
#
# Every node's requirements install runs under cache/constraints.txt (pins
# torch/torchvision/torchaudio/numpy), so a node dependency that conflicts
# fails loudly instead of silently downgrading torch. After each install we
# verify torch still sees CUDA and repair it from the recorded wheel lane.

NODES_FILE="$SUPERCOMFY_ROOT/supercomfy/nodes.txt"
CUSTOM_NODES_DIR="$COMFY_DIR/custom_nodes"

node_name_from_url() { basename "$1" .git; }

node_installed() { [ -d "$CUSTOM_NODES_DIR/$(node_name_from_url "$1")/.git" ]; }

# torch_verify_repair — if torch lost CUDA, reinstall the pinned trio from the
# lane recorded by install.sh. Dies only if the repair itself fails.
torch_verify_repair() {
  "$VENV_PY" -c 'import torch, sys; sys.exit(0 if torch.version.cuda else 1)' 2>/dev/null && return 0
  warn "torch lost its CUDA build — repairing from the recorded wheel lane"
  [ -f "$LANE_FILE" ] || die "Missing $LANE_FILE — run ./install.sh"
  # shellcheck source=/dev/null
  source "$LANE_FILE"
  local spec="torch==$TORCH_PIN torchvision==$TORCHVISION_PIN"
  [ -n "${TORCHAUDIO_PIN:-}" ] && spec="$spec torchaudio==$TORCHAUDIO_PIN"
  # shellcheck disable=SC2086  # spec is a deliberate word-split list
  uv pip install --python "$VENV_PY" --index-url "$TORCH_INDEX" --reinstall $spec \
    || die "torch repair failed — re-run ./install.sh"
  "$VENV_PY" -c 'import torch, sys; sys.exit(0 if torch.version.cuda else 1)' \
    || die "torch still broken after repair — re-run ./install.sh"
  ok "torch repaired ($("$VENV_PY" -c 'import torch; print(torch.__version__)'))"
}

# install_node <git-url> [ref] — clone or pull, then constrained requirements.
# Returns 0 installed/updated, 1 failed (callers keep going).
install_node() {
  local url="$1" ref="${2:-}" name dir
  name="$(node_name_from_url "$url")"
  dir="$CUSTOM_NODES_DIR/$name"
  mkdir -p "$CUSTOM_NODES_DIR"

  if [ -d "$dir/.git" ]; then
    git -C "$dir" pull --ff-only --quiet 2>/dev/null || warn "$name: could not update (local changes?) — keeping current version"
  else
    if ! git clone --quiet ${ref:+--branch "$ref"} --depth 1 "$url" "$dir"; then
      warn "$name: clone failed"
      return 1
    fi
  fi

  if [ -f "$dir/requirements.txt" ]; then
    [ -f "$CONSTRAINTS_FILE" ] || die "Missing $CONSTRAINTS_FILE — run ./install.sh"
    # shellcheck source=/dev/null
    source "$LANE_FILE"
    # unsafe-best-match: node deps live on PyPI but some names also exist (old)
    # on the torch index — let uv pick the best across both. The +cu130 torch
    # constraint still only matches the torch-index wheel, so torch stays safe.
    if ! uv pip install --python "$VENV_PY" -r "$dir/requirements.txt" \
        -c "$CONSTRAINTS_FILE" --extra-index-url "$TORCH_INDEX" \
        --index-strategy unsafe-best-match \
        > "$CACHE_DIR/node-$name.log" 2>&1; then
      warn "$name: requirements conflict with the pinned torch stack (see cache/node-$name.log) — node installed without them"
      torch_verify_repair
      return 1
    fi
  fi
  # An install script (Impact-Pack style) may also touch deps at first launch;
  # the gate here catches anything requirements just did.
  torch_verify_repair
  return 0
}

# read_nodes_file — echoes "url ref" lines, comments/blanks stripped.
read_nodes_file() {
  [ -f "$NODES_FILE" ] || die "Missing $NODES_FILE"
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$NODES_FILE"
}
