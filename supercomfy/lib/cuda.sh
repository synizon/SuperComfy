# CUDA detection and torch wheel-lane routing. Source after common.sh.
#
# One cu130 wheel covers every CUDA 13.x driver (13.0-13.3): NVIDIA minor-version
# compatibility only requires driver >= 580, and torch wheels bundle the CUDA
# runtime. cu132 exists but publishes no torchaudio wheels — never route there.

detect_cuda_version() { # echoes "MAJOR.MINOR" or nothing
  local v=""
  if command -v nvidia-smi >/dev/null 2>&1; then
    # sed -nE, not grep -oP: PCRE grep is unreliable on minimal images.
    # Old drivers print "CUDA Version: 13.0", 610+ prints "CUDA UMD Version: 13.3".
    v="$(nvidia-smi 2>/dev/null | sed -nE 's/.*CUDA (UMD )?Version: *([0-9]+\.[0-9]+).*/\2/p' | head -1)"
  fi
  if [ -z "$v" ] && command -v nvcc >/dev/null 2>&1; then
    v="$(nvcc --version 2>/dev/null | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' | head -1)"
  fi
  printf '%s' "$v"
}

# Sets: CUDA_DETECTED CU_TAG TORCH_INDEX TORCH_PIN TORCHVISION_PIN TORCHAUDIO_PIN
# Fails closed: no detected CUDA or an unsupported version is a hard error,
# never a silent fall-through to CPU wheels.
route_torch_lane() {
  CUDA_DETECTED="$(detect_cuda_version)"
  [ -n "$CUDA_DETECTED" ] || die "No NVIDIA CUDA detected (nvidia-smi and nvcc both unavailable).
    SuperComfy needs an NVIDIA GPU. Install the NVIDIA driver (>= 580 for CUDA 13.x) and retry."
  local major="${CUDA_DETECTED%%.*}" minor="${CUDA_DETECTED#*.}"

  # Defaults for the modern lanes; overridden per lane below.
  TORCH_PIN="2.13.0" TORCHVISION_PIN="0.28.0" TORCHAUDIO_PIN="2.11.0"
  if [ "$major" -ge 14 ]; then
    CU_TAG="cu130"
    warn "CUDA $CUDA_DETECTED is newer than any torch wheel lane — using cu130 (forward compatible)"
  elif [ "$major" -eq 13 ]; then
    CU_TAG="cu130"
  elif [ "$major" -eq 12 ] && [ "$minor" -ge 8 ]; then
    # The cu128 index stops before torch 2.13 / torchvision 0.28.
    CU_TAG="cu128" TORCH_PIN="2.11.0" TORCHVISION_PIN="0.26.0" TORCHAUDIO_PIN=""
  elif [ "$major" -eq 12 ] && [ "$minor" -ge 6 ]; then
    CU_TAG="cu126"
  elif [ "$major" -eq 12 ]; then
    CU_TAG="cu126"
    warn "CUDA $CUDA_DETECTED driver is old — installing cu126 wheels, but upgrade the driver when you can"
  else
    die "CUDA $CUDA_DETECTED is not supported (needs 12.0+, ideally 13.x / driver >= 580). Upgrade the NVIDIA driver."
  fi
  TORCH_INDEX="https://download.pytorch.org/whl/$CU_TAG"
}

# Persist the routed lane so downloadnodes.sh can repair torch if a node clobbers it.
save_torch_lane() {
  mkdir -p "$CACHE_DIR"
  {
    printf 'CU_TAG=%s\n' "$CU_TAG"
    printf 'TORCH_INDEX=%s\n' "$TORCH_INDEX"
    printf 'TORCH_PIN=%s\n' "$TORCH_PIN"
    printf 'TORCHVISION_PIN=%s\n' "$TORCHVISION_PIN"
    printf 'TORCHAUDIO_PIN=%s\n' "$TORCHAUDIO_PIN"
  } > "$LANE_FILE"
}
