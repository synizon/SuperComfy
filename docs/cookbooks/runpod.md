# RunPod deployment

Prebuilt image: `ghcr.io/synizon/supercomfy` (also tagged `:cuda-13.0.3` and
`:YYYYMMDD-<sha>`). Everything is baked — torch cu130, ComfyUI dependencies,
comfy-kitchen, JupyterLab, Caddy. At pod start the dashboard, password-protected
ComfyUI port, and token-protected JupyterLab come up within seconds; the ComfyUI
update and optional node preload (`deploy/runpod/prestart.sh`) run behind them,
and ComfyUI itself starts when they finish.

## Pod template

| Setting | Value |
| --- | --- |
| Container image | `ghcr.io/synizon/supercomfy:latest` |
| Container disk | **400 GB** (venv + ComfyUI + models live here) |
| Volume | 35 GB, mount path `/persistent` (durability mirror, not model storage) |
| Expose HTTP ports | `8080` (dashboard), `8188` (ComfyUI), `8888` (JupyterLab) |

Environment variables:

| Variable | Value |
| --- | --- |
| `COMFY_AUTH` | **required** — password for ComfyUI + dashboard (user `comfy`). Use a RunPod secret. |
| `JUPYTER_TOKEN` | optional — JupyterLab token (random + printed in logs if unset). Use a secret. |
| `SUPERCOMFY_VOLUME_DIR` | `/persistent` (must match the volume mount path) |
| `HF_TOKEN` | optional — gated/faster HuggingFace downloads |
| `PRELOAD_NODES` | optional — `1` installs every node in `supercomfy/nodes.txt` at start |

When deploying, filter GPUs with **CUDA Version = 13.0** (the image needs a
CUDA 13 host driver; RunPod hosts top out at 13.0). The GHCR package is
public, so no registry credential is needed. (GHCR creates a package private
on its first push — after the first workflow run, flip it once at
Package settings → Danger Zone → Change visibility.)

Without `COMFY_AUTH` the container refuses to expose ComfyUI and idles so you
can fix it from the web terminal (`SUPERCOMFY_INSECURE=1` overrides, at your
own risk).

## What the volume is (and is not)

The container disk is the working copy; the 35 GB volume at `/persistent` is a
durability mirror that survives pod stop/loss. Mirrored every 60 s and on
shutdown: `comfy/user` (workflows, settings), `comfy/output`, `comfy/input`,
`comfy/custom_nodes`, `.env`. On the next pod start these hydrate back.

Models are **not** mirrored — they are hundreds of re-downloadable GB. To also
mirror LoRAs, set
`SUPERCOMFY_MIRROR_ITEMS="comfy/user comfy/output comfy/input comfy/custom_nodes .env comfy/models/loras"`.

## Updates

- **ComfyUI and its dependencies**: update themselves at every pod start
  (the prestart hook runs `update.sh`), or run `./update.sh` from a terminal.
- **torch / comfy-kitchen / the baked stack**: rebuild the image — run the
  **RunPod image** workflow (Actions → RunPod image → Run workflow) with new
  versions, then redeploy the pod. There is no in-place upgrade path for the
  baked venv, by design.

## Local smoke test

```bash
docker build -f deploy/runpod/Dockerfile -t supercomfy:local .
docker run --rm --gpus all -e COMFY_AUTH=test -p 8080:8080 -p 8188:8188 supercomfy:local
```

Dashboard at http://127.0.0.1:8080, ComfyUI at http://127.0.0.1:8188
(user `comfy`, password `test`).

## Troubleshooting

- **"OCI runtime create failed" / CUDA driver errors at start** — the pod
  landed on a host with an older driver. Redeploy with the **CUDA Version =
  13.0** filter set.
- **Pod starts but nothing listens** — check the container logs: if
  `COMFY_AUTH is not set` appears, add it to the template (the container idles
  on purpose).
- **JupyterLab token** — the login URL (with token) is printed in the
  container logs at start; set `JUPYTER_TOKEN` to choose your own.
- **"403 Access denied" from the console's Connect button (port 8188)** —
  Cloudflare edge check on console-referred navigation, not a pod error.
  Open the pod URL in a fresh tab, or use the dashboard's Open ComfyUI
  button. The proxy itself never returns 403 (unready pods give 502,
  wrong ports 404).
- **Slow first pull** — the image is large (torch + CUDA libs). zstd layers
  extract fast; subsequent starts on the same host reuse the cache.
- **Custom node broke torch** — run `./update.sh` (or restart the pod); the
  constraints system reinstalls the pinned CUDA build.
