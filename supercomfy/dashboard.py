"""SuperComfy dashboard — one-file FastAPI app served by run.sh.

Binds loopback only; Caddy publishes it (with basic auth) on DASHBOARD_PORT.
Long tasks (node installs, model downloads, LoRA imports) shell out to the
same downloadnodes.sh / downloadmodels.sh the CLI uses, as one background
job at a time with its output in cache/jobs/<id>.log for the page to poll.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import urllib.request
import uuid

from fastapi import FastAPI, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMFY_DIR = os.path.join(ROOT, "comfy")
MODELS_DIR = os.path.join(COMFY_DIR, "models")
LORAS_DIR = os.path.join(MODELS_DIR, "loras")
NODES_FILE = os.path.join(ROOT, "supercomfy", "nodes.txt")
MODELS_JSON = os.path.join(ROOT, "supercomfy", "models.json")
STATIC_DIR = os.path.join(ROOT, "supercomfy", "static")
JOBS_DIR = os.path.join(ROOT, "cache", "jobs")
UPLOADS_DIR = os.path.join(ROOT, "cache", "uploads")

LORA_EXTS = (".safetensors", ".pt", ".ckpt")

app = FastAPI(title="SuperComfy")

# --- single-job runner -------------------------------------------------------

current_job: dict | None = None  # {"id", "title", "proc", "log"}


def start_job(title: str, cmd: list[str]) -> str:
    global current_job
    if current_job and current_job["proc"].poll() is None:
        raise HTTPException(409, f"A job is already running: {current_job['title']}")
    os.makedirs(JOBS_DIR, exist_ok=True)
    job_id = uuid.uuid4().hex[:12]
    log_path = os.path.join(JOBS_DIR, f"{job_id}.log")
    log = open(log_path, "wb")
    proc = subprocess.Popen(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL)
    current_job = {"id": job_id, "title": title, "proc": proc, "log": log_path}
    return job_id


@app.get("/api/jobs/{job_id}")
def job_status(job_id: str, offset: int = 0):
    if not current_job or current_job["id"] != job_id:
        raise HTTPException(404, "Unknown job")
    code = current_job["proc"].poll()
    text = ""
    size = offset
    try:
        with open(current_job["log"], "rb") as f:
            f.seek(offset)
            text = f.read().decode("utf-8", "replace")
            size = f.tell()
    except FileNotFoundError:
        pass
    # strip ANSI colors from the shell scripts
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    return {"id": job_id, "title": current_job["title"], "running": code is None,
            "exit_code": code, "log": text, "offset": size}


# --- status ------------------------------------------------------------------

def gpu_info():
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.total,memory.used",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5).stdout.strip().splitlines()
        name, total, used = [p.strip() for p in out[0].split(",")]
        return {"name": name, "vram_total_mb": int(total), "vram_used_mb": int(used)}
    except Exception:
        return None


def comfy_stats():
    port = os.environ.get("COMFY_LISTEN_PORT", os.environ.get("COMFY_PORT", "8188"))
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/system_stats", timeout=2) as r:
            return json.loads(r.read())
    except Exception:
        return None


def proxy_url(port: str) -> str | None:
    pod = os.environ.get("RUNPOD_POD_ID")
    return f"https://{pod}-{port}.proxy.runpod.net" if pod else None


@app.get("/api/status")
def status():
    stats = comfy_stats()
    disk = shutil.disk_usage(ROOT)
    comfy_port = os.environ.get("COMFY_PORT", "8188")
    jupyter_on = os.environ.get("JUPYTER_ENABLE") == "1" or "RUNPOD_POD_ID" in os.environ
    jupyter_port = os.environ.get("JUPYTER_PORT", "8888")
    return {
        "comfy_up": stats is not None,
        "comfy_version": (stats or {}).get("system", {}).get("comfyui_version"),
        "comfy_url": proxy_url(comfy_port),
        "comfy_port": int(comfy_port),
        "jupyter_url": proxy_url(jupyter_port) if jupyter_on else None,
        "jupyter_port": int(jupyter_port) if jupyter_on else None,
        "gpu": gpu_info(),
        "disk_free_gb": round(disk.free / 1e9, 1),
        "job": None if not current_job or current_job["proc"].poll() is not None
               else {"id": current_job["id"], "title": current_job["title"]},
    }


# --- nodes -------------------------------------------------------------------

@app.get("/api/nodes")
def nodes():
    items = []
    try:
        with open(NODES_FILE) as f:
            for line in f:
                line = line.split("#")[0].strip()
                if not line:
                    continue
                url = line.split()[0]
                name = os.path.basename(url).removesuffix(".git")
                installed = os.path.isdir(os.path.join(COMFY_DIR, "custom_nodes", name, ".git"))
                items.append({"name": name, "url": url, "installed": installed})
    except FileNotFoundError:
        pass
    return {"nodes": items}


@app.post("/api/nodes/install-all")
def nodes_install_all():
    return {"job": start_job("Installing custom nodes",
                             [os.path.join(ROOT, "downloadnodes.sh"), "--all"])}


# --- models ------------------------------------------------------------------

@app.get("/api/models")
def models():
    try:
        with open(MODELS_JSON) as f:
            data = json.load(f)
    except FileNotFoundError:
        raise HTTPException(500, "supercomfy/models.json is missing")
    out = {}
    for cat, entries in data.items():
        out[cat] = []
        for e in entries:
            fname = os.path.basename(e["url"].split("?")[0])
            present = os.path.isfile(os.path.join(MODELS_DIR, e["dest"], fname))
            out[cat].append({**e, "present": present})
    return {"categories": out}


class DownloadReq(BaseModel):
    items: list[str]  # "category/Model Name"


@app.post("/api/models/download")
def models_download(req: DownloadReq):
    if not req.items:
        raise HTTPException(400, "Nothing selected")
    cmd = [os.path.join(ROOT, "downloadmodels.sh")]
    for item in req.items:
        cmd += ["--get", item]
    return {"job": start_job(f"Downloading {len(req.items)} model(s)", cmd)}


# --- LoRAs -------------------------------------------------------------------

class LoraLinkReq(BaseModel):
    url: str


@app.post("/api/lora/link")
def lora_link(req: LoraLinkReq):
    url = req.url.strip()
    if not url.startswith(("http://", "https://")):
        raise HTTPException(400, "Not a URL")
    return {"job": start_job("Importing LoRA from link",
                             [os.path.join(ROOT, "downloadmodels.sh"), "--lora", url])}


@app.post("/api/lora/upload")
async def lora_upload(file: UploadFile):
    name = os.path.basename(file.filename or "")
    if not name or not name.lower().endswith(LORA_EXTS + (".zip",)):
        raise HTTPException(400, "Only .safetensors/.pt/.ckpt or .zip files")
    if name.lower().endswith(".zip"):
        os.makedirs(UPLOADS_DIR, exist_ok=True)
        dest_dir, is_zip = UPLOADS_DIR, True
    else:
        os.makedirs(LORAS_DIR, exist_ok=True)
        dest_dir, is_zip = LORAS_DIR, False
    dest = os.path.realpath(os.path.join(dest_dir, name))
    if not dest.startswith(os.path.realpath(dest_dir) + os.sep):
        raise HTTPException(400, "Bad filename")
    with open(dest, "wb") as out:  # stream — LoRAs can be multi-GB
        while chunk := await file.read(1 << 20):
            out.write(chunk)
    if is_zip:
        return {"job": start_job(f"Extracting {name}",
                                 [os.path.join(ROOT, "downloadmodels.sh"), "--lora", dest])}
    return {"job": None, "saved": f"comfy/models/loras/{name}"}


# --- page --------------------------------------------------------------------

@app.get("/")
def index():
    return FileResponse(os.path.join(STATIC_DIR, "index.html"))


if __name__ == "__main__":
    import uvicorn
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=int(os.environ.get("DASHBOARD_BIND_PORT", "8081")))
    args = parser.parse_args()
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")
