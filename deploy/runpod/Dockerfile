# syntax=docker/dockerfile:1.7
# SuperComfy RunPod image. The builder stage assembles the venv from wheels
# (nothing is compiled); the final stage is the slim CUDA base plus the baked
# venv (torch wheels bundle the CUDA runtime, so only the host driver matters).
# The repo lives at /opt/supercomfy with the venv at its normal cache/venv
# path, so run.sh, update.sh, and the download scripts work unmodified.
# Built by .github/workflows/runpod-image.yml; template guide in
# docs/cookbooks/runpod.md.
ARG BASE_BUILDER=docker.io/nvidia/cuda:13.0.3-base-ubuntu24.04
ARG BASE_FINAL=docker.io/nvidia/cuda:13.0.3-base-ubuntu24.04

FROM ${BASE_BUILDER} AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
ARG TORCH_VERSION=2.13.0
ARG TORCHVISION_VERSION=0.28.0
ARG TORCHAUDIO_VERSION=2.11.0
ARG COMFYUI_REF=v0.33.3

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/root/.local/bin:$PATH \
    VENV=/opt/supercomfy/cache/venv \
    VENV_PY=/opt/supercomfy/cache/venv/bin/python \
    CONSTRAINTS=/opt/supercomfy/cache/constraints.txt

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git \
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
required = ["torchvision", "torchaudio", "comfy_kitchen",
            "fastapi", "uvicorn", "multipart", "jupyterlab", "huggingface_hub"]
missing = [m for m in required if importlib.util.find_spec(m) is None]
if missing:
    sys.exit(f"missing baked modules: {missing}")
print(f"torch={torch.__version__} cuda={torch.version.cuda}")
PYEOF

WORKDIR /opt/supercomfy
EXPOSE 8080 8188 8888
ENTRYPOINT ["bash", "/opt/supercomfy/deploy/runpod/entrypoint.sh"]
