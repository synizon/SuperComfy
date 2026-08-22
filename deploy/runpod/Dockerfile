# syntax=docker/dockerfile:1.7
# SuperComfy RunPod image. The builder stage compiles SageAttention with nvcc;
# the final stage is the slim CUDA base plus the baked venv (torch wheels
# bundle the CUDA runtime, so only the host driver matters). The repo lives at
# /opt/supercomfy with the venv at its normal cache/venv path, so run.sh,
# update.sh, and the download scripts work unmodified.
# Built by .github/workflows/runpod-image.yml; template guide in
# docs/cookbooks/runpod.md.
ARG BASE_BUILDER=docker.io/nvidia/cuda:13.0.3-cudnn-devel-ubuntu24.04
ARG BASE_FINAL=docker.io/nvidia/cuda:13.0.3-base-ubuntu24.04

FROM ${BASE_BUILDER} AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
ARG TORCH_VERSION=2.13.0
ARG TORCHVISION_VERSION=0.28.0
ARG TORCHAUDIO_VERSION=2.11.0
ARG COMFYUI_REF=v0.33.3
# woct0rdho's fork of thu-ml/SageAttention: upstream passes every -gencode to
# every extension, so a multi-arch list mixing Hopper (9.0) and Blackwell (12.0)
# fails (wgmma PTX can't target sm_120). The fork scopes arch flags per
# extension; it still builds and reports sageattention 2.2.0.
ARG SAGE_REPO=https://github.com/woct0rdho/SageAttention.git
ARG SAGE_REF=v2.2.0-windows.post6
# Every arch SageAttention 2.2 supports on CUDA 13 hosts (Ampere..Blackwell).
ARG TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0;12.0"

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/root/.local/bin:$PATH \
    VENV=/opt/supercomfy/cache/venv \
    VENV_PY=/opt/supercomfy/cache/venv/bin/python \
    CONSTRAINTS=/opt/supercomfy/cache/constraints.txt

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git ninja-build \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && uv python install 3.13 \
    && uv venv --python 3.13 "$VENV"

# torch gets its own layer: it dominates image size, so keeping it independent
# of everything below lets rebuilds reuse it and pods pull it in parallel.
# The constraints + lane files mirror what install.sh writes, so update.sh and
# downloadnodes.sh can refresh dependencies at pod start without clobbering torch.
RUN uv pip install --python "$VENV_PY" --index-url "$TORCH_INDEX_URL" \
        "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" \
        "torchaudio==${TORCHAUDIO_VERSION}" \
    && uv pip freeze --python "$VENV_PY" \
        | grep -E '^(torch|torchvision|torchaudio|numpy)==' > "$CONSTRAINTS" \
    && printf 'CU_TAG=%s\nTORCH_INDEX=%s\nTORCH_PIN=%s\nTORCHVISION_PIN=%s\nTORCHAUDIO_PIN=%s\n' \
        "${TORCH_INDEX_URL##*/}" "$TORCH_INDEX_URL" "$TORCH_VERSION" \
        "$TORCHVISION_VERSION" "$TORCHAUDIO_VERSION" \
        > /opt/supercomfy/cache/torch-lane.env

# ComfyUI requirements for the pinned release; the entrypoint refreshes them
# against the latest release at pod start (update.sh, same constraints).
RUN curl -fsSL "https://raw.githubusercontent.com/Comfy-Org/ComfyUI/${COMFYUI_REF}/requirements.txt" \
        -o /tmp/comfy-requirements.txt \
    && uv pip install --python "$VENV_PY" -r /tmp/comfy-requirements.txt \
        -c "$CONSTRAINTS" --extra-index-url "$TORCH_INDEX_URL" \
    && uv pip freeze --python "$VENV_PY" \
        | grep -E '^(torch|torchvision|torchaudio|numpy)==' > "$CONSTRAINTS"

RUN uv pip install --python "$VENV_PY" -c "$CONSTRAINTS" \
        fastapi uvicorn python-multipart comfy-kitchen \
        "jupyterlab>=4.6,<5" "huggingface_hub[cli]"

# flash-attn: no official cu13 wheels; best effort from mjun0812's prebuilt
# index (same resolver as install.sh) — the image still builds without it.
RUN <<'EOF'
set -uo pipefail
wheel="$("$VENV_PY" - "${TORCH_INDEX_URL##*/}" "$TORCH_VERSION" <<'PYEOF' || true
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
if [ -n "$wheel" ]; then
    uv pip install --python "$VENV_PY" -c "$CONSTRAINTS" "$wheel" \
        || echo "flash-attn wheel failed to install — continuing without it"
else
    echo "No prebuilt flash-attn wheel — continuing without it"
fi
EOF

# SageAttention 2.2 must be compiled (PyPI's package is a stale 1.x).
# Its setup.py hardcodes nvcc --threads=8, so each MAX_JOBS job compiles up to
# 6 arch variants in parallel at ~2.5GB per cicc (~15GB+ per job). Size jobs by
# available memory or the OOM killer ends the build (16GB CI runners get 1 job).
RUN uv pip install --python "$VENV_PY" setuptools wheel packaging ninja \
    && mem_kb="$(grep MemAvailable /proc/meminfo | awk '{print $2}')" \
    && jobs=$(( mem_kb / 18874368 )) \
    && if [ "$jobs" -gt "$(nproc)" ]; then jobs="$(nproc)"; fi \
    && if [ "$jobs" -gt 4 ]; then jobs=4; fi \
    && if [ "$jobs" -lt 1 ]; then jobs=1; fi \
    && echo "Compiling SageAttention with MAX_JOBS=$jobs" \
    && MAX_JOBS="$jobs" uv pip install --python "$VENV_PY" \
        -c "$CONSTRAINTS" --no-build-isolation \
        "git+${SAGE_REPO}@${SAGE_REF}"

# Park the nvidia CUDA libs (~half the venv) behind a symlink so the final
# stage can copy them as their own layer — two big layers pull in parallel.
RUN mv "$VENV/lib/python3.13/site-packages/nvidia" /opt/nvidia-pkgs \
    && ln -s /opt/nvidia-pkgs "$VENV/lib/python3.13/site-packages/nvidia"

FROM ${BASE_FINAL}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG COMFYUI_REF=v0.33.3

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/supercomfy/cache/venv/bin:/root/.local/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        aria2 ca-certificates curl git libgl1 libglib2.0-0 lsof rsync unzip \
    && rm -rf /var/lib/apt/lists/*

# uv + its managed Python 3.13 (the venv symlinks into it), then the venv in
# two parallel-pull layers (nvidia libs split out by the builder above).
COPY --from=builder /root/.local/bin/uv /root/.local/bin/uv
COPY --from=builder /root/.local/share/uv /root/.local/share/uv
COPY --from=builder /opt/nvidia-pkgs /opt/nvidia-pkgs
COPY --from=builder /opt/supercomfy/cache /opt/supercomfy/cache

# ComfyUI at the pinned release; the entrypoint moves it to the latest release
# at pod start. .installed matches so run.sh does not warn about the baked state.
RUN git clone --filter=blob:none https://github.com/Comfy-Org/ComfyUI /opt/supercomfy/comfy \
    && git -C /opt/supercomfy/comfy -c advice.detachedHead=false checkout --quiet "$COMFYUI_REF" \
    && sha256sum /opt/supercomfy/comfy/requirements.txt | cut -d' ' -f1 \
        > /opt/supercomfy/cache/venv/.installed

# Caddy (auth proxy) where run.sh's ensure_caddy expects it.
RUN mkdir -p /opt/supercomfy/cache/bin \
    && curl -fsSL -o /opt/supercomfy/cache/bin/caddy \
        "https://caddyserver.com/api/download?os=linux&arch=amd64" \
    && chmod +x /opt/supercomfy/cache/bin/caddy \
    && /opt/supercomfy/cache/bin/caddy version

COPY . /opt/supercomfy
COPY deploy/runpod/root.bashrc /root/.bashrc
COPY deploy/runpod/jupyter_server_config.py /root/.jupyter/jupyter_server_config.py
RUN echo '. /root/.bashrc' > /root/.bash_profile

# The image must not build with a broken environment.
RUN python - <<'PYEOF'
import importlib.util, sys
import torch
assert sys.version_info[:2] == (3, 13), sys.version
assert torch.version.cuda and torch.version.cuda.startswith("13."), torch.version.cuda
required = ["torchvision", "torchaudio", "sageattention", "comfy_kitchen",
            "fastapi", "uvicorn", "multipart", "jupyterlab", "huggingface_hub"]
missing = [m for m in required if importlib.util.find_spec(m) is None]
if missing:
    sys.exit(f"missing baked modules: {missing}")
if importlib.util.find_spec("flash_attn") is None:
    print("note: flash_attn not baked (no prebuilt wheel matched)")
print(f"torch={torch.__version__} cuda={torch.version.cuda}")
PYEOF

WORKDIR /opt/supercomfy
EXPOSE 8080 8188 8888
ENTRYPOINT ["bash", "/opt/supercomfy/deploy/runpod/entrypoint.sh"]
