# SuperComfy

Easy ComfyUI installer and launcher for Linux and RunPod, built for CUDA 13.x
(13.0–13.3). One command installs the latest ComfyUI release with the right
PyTorch wheels; one command runs it with your preferred attention backend and
optional password protection.

## Requirements

- Linux, NVIDIA GPU, driver 580+ (CUDA 13.x) — CUDA 12.6+ also works
- `git` and `curl` (everything else, including Python 3.13, is installed for you)

## Install

```bash
git clone https://github.com/synizon/SuperComfy
cd SuperComfy
./install.sh
```

`./install.sh --dry-run` shows the detected CUDA version and the torch wheels
that would be installed, without changing anything.

## Run

```bash
./run.sh
```

First run asks for a speed/quality preset (saved to `.env`, change later with
`./run.sh --select`):

| Preset | Flag | Notes |
| --- | --- | --- |
| pytorch | `--use-pytorch-cross-attention` | default, always works |
| sage | `--use-sage-attention` | SageAttention 2.2, fastest on RTX 30xx+ (needs nvcc at install time) |
| flash | `--use-flash-attention` | FlashAttention 2 (prebuilt wheel, when available) |
| comfy-kitchen | `--use-ck-attention` | Comfy-Org optimized kernels |

Then open http://127.0.0.1:8188 (or the printed RunPod proxy URL).

## Dashboard

run.sh also serves a web dashboard on port 8080 (URL printed at start): open
ComfyUI or JupyterLab, install the custom nodes, download catalog models, and
import LoRAs by drag-and-drop, HuggingFace link, or zip — all from the browser.
It runs the same shell scripts as the CLI, showing their live log. With
`COMFY_AUTH` set it sits behind the same password as ComfyUI; without it, it
stays on 127.0.0.1. Change the port with `DASHBOARD_PORT` in `.env`.

## Update

```bash
./update.sh              # latest ComfyUI release + refreshed dependencies
./update.sh --comfy-only # just the ComfyUI code
```

## Password protection

Set `COMFY_AUTH=yourpassword` in `.env`. run.sh then fronts ComfyUI and the
dashboard with a Caddy basic-auth proxy (user `comfy`). Exposing to the network without a
password is refused. JupyterLab (optional, `JUPYTER_ENABLE=1`) is protected by
`JUPYTER_TOKEN`, or a random token that is printed at start.

## Layout

```
comfy/            ComfyUI itself (cloned by install.sh, gitignored)
cache/            venv + runtime state (gitignored)
.env              your settings and passwords (gitignored; see .env.example)
install.sh        installer
run.sh            launcher
update.sh         updater
downloadnodes.sh  popular custom nodes
downloadmodels.sh model downloads + LoRA import
supercomfy/       SuperComfy's own code (edit nodes.txt / models.json here)
```

## Custom nodes and dependency safety

```bash
./downloadnodes.sh        # pick nodes from a menu
./downloadnodes.sh --all  # install everything in supercomfy/nodes.txt
```

The node list lives in `supercomfy/nodes.txt` — one git URL per line, edit
freely. Custom nodes often pip-install their own requirements and silently
replace torch with a CPU build. SuperComfy installs every node's requirements
under a constraints file that pins torch/torchvision/torchaudio/numpy, then
verifies torch still sees CUDA — and repairs it if not. A node whose
requirements conflict is refused instead of breaking the install.

## Models and LoRAs

```bash
./downloadmodels.sh                       # category menu from supercomfy/models.json
./downloadmodels.sh --all                 # everything in the catalog
./downloadmodels.sh --lora <target>       # import a LoRA
```

The catalog lives in `supercomfy/models.json` (name, url, dest folder) — edit
freely. Downloads resume, and files already present at the right size are
skipped. Set `HF_TOKEN` in `.env` for gated/faster HuggingFace downloads.

`--lora` accepts a HuggingFace file or repo link, a direct URL, or a local
`.zip` / `.safetensors` / `.pt` / `.ckpt` file. Zips are extracted flat into
`comfy/models/loras/` keeping only the weight files.

## RunPod

Deploy the prebuilt image `ghcr.io/synizon/supercomfy` — everything is baked
(torch cu130, SageAttention compiled, JupyterLab, Caddy) and ComfyUI updates
itself to the latest release at every pod start. Template: 400 GB container
disk, a 35 GB volume at `/persistent` (mirrors workflows/outputs/`.env` for
durability), HTTP ports 8080/8188/8888, env `COMFY_AUTH` (required) +
`JUPYTER_TOKEN`, and the **CUDA Version = 13.0** GPU filter. Full checklist,
update paths, and troubleshooting: [docs/cookbooks/runpod.md](docs/cookbooks/runpod.md).

The image is built by the **RunPod image** GitHub Action
(`.github/workflows/runpod-image.yml`, manual dispatch). The scripts also
detect RunPod when run directly (proxy URLs, 0.0.0.0 bind, JupyterLab on).
