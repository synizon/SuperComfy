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

## Update

```bash
./update.sh              # latest ComfyUI release + refreshed dependencies
./update.sh --comfy-only # just the ComfyUI code
```

## Password protection

Set `COMFY_AUTH=yourpassword` in `.env`. run.sh then fronts ComfyUI with a
Caddy basic-auth proxy (user `comfy`). Exposing to the network without a
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

A prebuilt Docker image and pod template guide ship in a later release; the
scripts already detect RunPod (proxy URLs, 0.0.0.0 bind, JupyterLab on).
