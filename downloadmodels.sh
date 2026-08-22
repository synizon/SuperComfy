#!/usr/bin/env bash
# Download models from the supercomfy/models.json catalog into comfy/models/,
# and import LoRAs from HuggingFace links, direct URLs, or local zip files.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=supercomfy/lib/common.sh
source "$SCRIPT_DIR/supercomfy/lib/common.sh"
# shellcheck source=supercomfy/lib/models.sh
source "$SCRIPT_DIR/supercomfy/lib/models.sh"

ALL=0 LORA_TARGET="" GETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1 ;;
    --lora)
      [ $# -ge 2 ] || die "--lora needs a target (HF link, URL, or local .zip/.safetensors)"
      LORA_TARGET="$2"; shift ;;
    --get)
      [ $# -ge 2 ] || die "--get needs 'category/Model Name' from supercomfy/models.json"
      GETS+=("$2"); shift ;;
    -h|--help)
      echo "Usage: ./downloadmodels.sh [--all] [--get <category/name>]... [--lora <target>]"
      echo "  --all             download every model in supercomfy/models.json (no menu)"
      echo "  --get <cat/name>  download one catalog model by category/name (repeatable)"
      echo "  --lora <target>   import a LoRA: HuggingFace link, direct URL,"
      echo "                    or local .zip/.safetensors/.pt/.ckpt file"
      exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

banner "Model downloads"
load_env
need_cmd curl
[ -x "$VENV_PY" ] && [ -d "$COMFY_DIR" ] || die "SuperComfy is not installed yet — run ./install.sh first"
ensure_uv

if [ -n "$LORA_TARGET" ]; then
  import_lora "$LORA_TARGET"
  exit 0
fi

# download_entries "cat<TAB>name<TAB>url<TAB>dest<TAB>size" lines -> summary
downloaded=() failed=()
download_entries() {
  local entry name url dest
  for entry in "$@"; do
    IFS=$'\t' read -r _ name url dest _ <<< "$entry"
    step "Downloading $name"
    if download_model "$name" "$url" "$dest"; then
      downloaded+=("$name")
    else
      failed+=("$name")
    fi
  done
}

mapfile -t all_entries < <(read_models_file)
[ ${#all_entries[@]} -gt 0 ] || die "supercomfy/models.json has no models"

if [ ${#GETS[@]} -gt 0 ]; then
  selected=()
  for g in "${GETS[@]}"; do
    case "$g" in */*) ;; *) die "--get wants 'category/Model Name', got: $g" ;; esac
    want_cat="${g%%/*}" want_name="${g#*/}"
    entry="$(printf '%s\n' "${all_entries[@]}" \
      | awk -F'\t' -v c="$want_cat" -v n="$want_name" '$1==c && $2==n' | head -1)"
    [ -n "$entry" ] || die "Not in supercomfy/models.json: $g"
    selected+=("$entry")
  done
  download_entries "${selected[@]}"
elif [ "$ALL" -eq 1 ] || [ ! -t 0 ]; then
  download_entries "${all_entries[@]}"
else
  mapfile -t cats < <(model_categories)
  while :; do
    step "Model categories (from supercomfy/models.json)"
    i=1
    for cat in "${cats[@]}"; do
      count="$(printf '%s\n' "${all_entries[@]}" | cut -f1 | grep -cx "$cat" || true)"
      printf '  %2d) %-18s %s(%s models)%s\n' "$i" "$cat" "$C_DIM" "$count" "$C_RESET"
      i=$((i + 1))
    done
    printf '\n'
    read -rp "  Category [1-${#cats[@]}] (a = download all, q = quit): " pick
    case "$pick" in
      q|Q|'') break ;;
      a|A) download_entries "${all_entries[@]}"; break ;;
    esac
    idx="$(parse_selection "${#cats[@]}" "$pick" | head -1)"
    cat="${cats[$((idx-1))]}"

    mapfile -t entries < <(read_models_file "$cat")
    if [ ${#entries[@]} -eq 0 ]; then
      warn "No models in $cat yet — edit supercomfy/models.json to add some"
      continue
    fi
    printf '\n'
    step "$cat"
    i=1
    for entry in "${entries[@]}"; do
      IFS=$'\t' read -r _ name url dest size <<< "$entry"
      mark=" "
      [ -f "$MODELS_DIR/$dest/$(model_file_from_url "$url")" ] && mark="${C_GREEN}✔${C_RESET}"
      printf '  %2d) [%b] %-24s %s%s%s\n' "$i" "$mark" "$name" "$C_DIM" "$size" "$C_RESET"
      i=$((i + 1))
    done
    printf '\n'
    read -rp "  Download which? (numbers/ranges like 1 3 5-7, a = all here, b = back): " pick
    case "$pick" in
      b|B|q|Q|'') continue ;;
      a|A) selected=("${entries[@]}") ;;
      *)
        selected=()
        idxs="$(parse_selection "${#entries[@]}" "$pick")"
        for n in $idxs; do selected+=("${entries[$((n-1))]}"); done ;;
    esac
    download_entries "${selected[@]}"
    printf '\n'
  done
fi

printf '\n'
step "Summary"
ok "Downloaded/present: ${#downloaded[@]}"
if [ ${#failed[@]} -gt 0 ]; then
  warn "Failed: ${failed[*]}"
  exit 1
fi
