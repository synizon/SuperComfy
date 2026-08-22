# Model download helpers. Source after common.sh.
#
# The catalog lives in supercomfy/models.json (edit freely):
#   { "<category>": [ {"name", "url", "dest", "size"}, ... ], ... }
# "dest" is the subfolder under comfy/models/. "size" is display-only — the
# skip/resume check compares the local file against the server's Content-Length.

MODELS_JSON="$SUPERCOMFY_ROOT/supercomfy/models.json"
MODELS_DIR="$COMFY_DIR/models"
LORAS_DIR="$MODELS_DIR/loras"

# read_models_file [category] — one entry per line: category<TAB>name<TAB>url<TAB>dest<TAB>size
read_models_file() {
  [ -f "$MODELS_JSON" ] || die "Missing $MODELS_JSON"
  "$VENV_PY" - "$MODELS_JSON" "${1:-}" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
want = sys.argv[2]
for cat, entries in data.items():
    if want and cat != want:
        continue
    for e in entries:
        print("\t".join([cat, e["name"], e["url"], e["dest"], e.get("size", "?")]))
PY
}

model_categories() { read_models_file | cut -f1 | awk '!seen[$0]++'; }

is_hf_url() { case "$1" in https://huggingface.co/*) return 0 ;; *) return 1 ;; esac; }

model_file_from_url() { local f="${1%%\?*}"; basename "$f"; }

# remote_size URL — echoes the Content-Length in bytes (empty if unknown).
remote_size() {
  local -a hdr=()
  is_hf_url "$1" && [ -n "${HF_TOKEN:-}" ] && hdr=(-H "Authorization: Bearer $HF_TOKEN")
  curl -sIL "${hdr[@]}" "$1" 2>/dev/null | tr -d '\r' \
    | awk 'tolower($1)=="content-length:"{n=$2} END{if (n) print n}'
}

ensure_hf_cli() {
  [ -x "$VENV_DIR/bin/huggingface-cli" ] && return 0
  step "Installing huggingface_hub (HF downloader)"
  uv pip install --python "$VENV_PY" -c "$CONSTRAINTS_FILE" 'huggingface_hub[cli]' \
    > "$CACHE_DIR/hf-cli-install.log" 2>&1 || return 1
  [ -x "$VENV_DIR/bin/huggingface-cli" ]
}

# hf_fetch URL TARGET — download an HF resolve/blob URL with huggingface-cli
# (respects HF_TOKEN, resumes). Returns 1 if the URL has no file path.
hf_fetch() {
  local url="$1" target="$2" parsed repo rev path tmp
  parsed="$("$VENV_PY" - "$url" <<'PY'
import sys, urllib.parse
parts = [p for p in urllib.parse.urlparse(sys.argv[1]).path.split('/') if p]
if len(parts) < 5 or parts[2] not in ("resolve", "blob"):
    sys.exit(1)
print("\t".join([f"{parts[0]}/{parts[1]}", parts[3], "/".join(parts[4:])]))
PY
)" || return 1
  IFS=$'\t' read -r repo rev path <<< "$parsed"
  ensure_hf_cli || return 1
  tmp="$CACHE_DIR/hf-tmp"
  HF_TOKEN="${HF_TOKEN:-}" "$VENV_DIR/bin/huggingface-cli" download \
    "$repo" "$path" --revision "$rev" --local-dir "$tmp" >/dev/null || return 1
  mkdir -p "$(dirname "$target")"
  mv -f "$tmp/$path" "$target"
}

# direct_fetch URL TARGET — aria2c (parallel, resumable) or curl (-C - resume).
direct_fetch() {
  local url="$1" target="$2" auth=""
  local -a a_hdr=() c_hdr=()
  is_hf_url "$url" && [ -n "${HF_TOKEN:-}" ] && auth="Authorization: Bearer $HF_TOKEN"
  [ -n "$auth" ] && { a_hdr=(--header="$auth"); c_hdr=(-H "$auth"); }
  mkdir -p "$(dirname "$target")"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -x8 -s8 -c --console-log-level=warn "${a_hdr[@]}" \
      -d "$(dirname "$target")" -o "$(basename "$target")" "$url"
  else
    curl -L --fail --retry 3 -C - --progress-bar "${c_hdr[@]}" -o "$target" "$url"
  fi
}

# download_model NAME URL DEST_SUBDIR — into comfy/models/<dest>. Skips when the
# local file already matches the server size; resumes partial files. Returns 1
# on failure (callers keep going).
download_model() {
  local name="$1" url="$2" destsub="$3" dir target want have
  dir="$MODELS_DIR/$destsub"
  target="$dir/$(model_file_from_url "$url")"
  mkdir -p "$dir"
  want="$(remote_size "$url")"
  if [ -f "$target" ]; then
    have="$(stat -c %s "$target")"
    if [ -z "$want" ] || [ "$have" = "$want" ]; then
      ok "$name already downloaded — skipping"
      return 0
    fi
    warn "$name is partial ($have of $want bytes) — resuming"
  fi
  if is_hf_url "$url"; then
    hf_fetch "$url" "$target" \
      || { warn "$name: huggingface-cli path failed — trying direct download"; direct_fetch "$url" "$target"; } \
      || { warn "$name: download failed"; return 1; }
  else
    direct_fetch "$url" "$target" || { warn "$name: download failed"; return 1; }
  fi
  [ -s "$target" ] || { warn "$name: download produced no file"; return 1; }
  ok "$name -> comfy/models/$destsub/$(basename "$target")"
}

# import_lora TARGET — HF link (blob/resolve/repo), direct URL, or local
# .zip / .safetensors / .pt / .ckpt. Everything lands flat in comfy/models/loras/.
import_lora() {
  local target="$1" file
  mkdir -p "$LORAS_DIR"
  # HF file links: blob/ pages point at HTML — swap for the raw resolve/ URL.
  case "$target" in
    https://huggingface.co/*/blob/*) target="${target/\/blob\//\/resolve\/}" ;;
  esac
  case "$target" in
    https://huggingface.co/*/resolve/*|http://*|https://*)
      if is_hf_url "$target" && [[ "$target" != */resolve/* ]]; then
        # Bare repo link — grab every .safetensors in it.
        local repo tmp
        repo="$("$VENV_PY" - "$target" <<'PY'
import sys, urllib.parse
parts = [p for p in urllib.parse.urlparse(sys.argv[1]).path.split('/') if p]
if len(parts) < 2:
    sys.exit(1)
print(f"{parts[0]}/{parts[1]}")
PY
)" || die "Could not read a repo id from: $target"
        ensure_hf_cli || die "huggingface_hub install failed (see cache/hf-cli-install.log)"
        tmp="$CACHE_DIR/lora-tmp"
        HF_TOKEN="${HF_TOKEN:-}" "$VENV_DIR/bin/huggingface-cli" download \
          "$repo" --include '*.safetensors' --local-dir "$tmp" >/dev/null \
          || die "Download failed for $repo"
        find "$tmp" -name '*.safetensors' -exec mv -f {} "$LORAS_DIR/" \;
        ok "LoRAs from $repo -> comfy/models/loras/"
        return 0
      fi
      file="$(model_file_from_url "$target")"
      case "$file" in
        *.safetensors|*.pt|*.ckpt) ;;
        *) die "Not a LoRA file (.safetensors/.pt/.ckpt): $file" ;;
      esac
      download_model "$file" "$target" "loras" || die "LoRA download failed"
      ;;
    *.zip)
      [ -f "$target" ] || die "No such file: $target"
      step "Extracting LoRAs from $(basename "$target")"
      # Flat extract by basename (immune to zip-slip paths), weights only.
      "$VENV_PY" - "$target" "$LORAS_DIR" <<'PY' || die "Zip import failed"
import os, shutil, sys, zipfile
zpath, dest = sys.argv[1], sys.argv[2]
kept = 0
with zipfile.ZipFile(zpath) as z:
    for info in z.infolist():
        if info.is_dir():
            continue
        base = os.path.basename(info.filename)
        if not base.lower().endswith((".safetensors", ".pt")):
            continue
        with z.open(info) as src, open(os.path.join(dest, base), "wb") as out:
            shutil.copyfileobj(src, out)
        print(f"  extracted {base}")
        kept += 1
if kept == 0:
    sys.exit("no .safetensors/.pt files inside the zip")
PY
      ok "Zip imported -> comfy/models/loras/"
      ;;
    *.safetensors|*.pt|*.ckpt)
      [ -f "$target" ] || die "No such file: $target"
      cp -f "$target" "$LORAS_DIR/"
      ok "$(basename "$target") -> comfy/models/loras/"
      ;;
    *)
      die "Unsupported LoRA target: $target
    Use a HuggingFace link, a direct URL, or a local .zip/.safetensors/.pt/.ckpt file."
      ;;
  esac
}
