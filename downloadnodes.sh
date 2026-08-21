#!/usr/bin/env bash
# Install popular ComfyUI custom nodes (list in supercomfy/nodes.txt) without
# letting any node break the torch/CUDA install.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=supercomfy/lib/common.sh
source "$SCRIPT_DIR/supercomfy/lib/common.sh"
# shellcheck source=supercomfy/lib/nodes.sh
source "$SCRIPT_DIR/supercomfy/lib/nodes.sh"

ALL=0
for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    -h|--help)
      echo "Usage: ./downloadnodes.sh [--all]"
      echo "  --all   install every node in supercomfy/nodes.txt (no menu)"
      exit 0 ;;
    *) die "Unknown option: $arg (try --help)" ;;
  esac
done

banner "Custom nodes"
load_env
need_cmd git
[ -x "$VENV_PY" ] && [ -d "$COMFY_DIR" ] || die "SuperComfy is not installed yet — run ./install.sh first"
ensure_uv

mapfile -t entries < <(read_nodes_file)
[ ${#entries[@]} -gt 0 ] || die "supercomfy/nodes.txt is empty"

selected=()
if [ "$ALL" -eq 1 ] || [ ! -t 0 ]; then
  selected=("${entries[@]}")
else
  step "Available nodes (from supercomfy/nodes.txt)"
  i=1
  for entry in "${entries[@]}"; do
    url="${entry%% *}"
    name="$(node_name_from_url "$url")"
    mark=" "
    node_installed "$url" && mark="${C_GREEN}✔${C_RESET}"
    printf '  %2d) [%b] %s\n' "$i" "$mark" "$name"
    i=$((i + 1))
  done
  printf '\n'
  read -rp "  Install which? (numbers/ranges like 1 3 5-7, a = all, q = quit): " pick
  case "$pick" in
    q|Q) exit 0 ;;
    a|A|'') selected=("${entries[@]}") ;;
    *)
      for tok in $pick; do
        case "$tok" in
          *-*) start="${tok%-*}"; end="${tok#*-}" ;;
          *)   start="$tok"; end="$tok" ;;
        esac
        [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || die "Bad selection: $tok"
        for ((n=start; n<=end; n++)); do
          [ "$n" -ge 1 ] && [ "$n" -le ${#entries[@]} ] || die "Out of range: $n"
          selected+=("${entries[$((n-1))]}")
        done
      done ;;
  esac
fi

installed=() failed=()
for entry in "${selected[@]}"; do
  url="${entry%% *}"
  ref=""
  [ "$entry" != "$url" ] && ref="${entry#* }"
  name="$(node_name_from_url "$url")"
  step "Installing $name"
  if install_node "$url" "$ref"; then
    installed+=("$name")
    ok "$name ready"
  else
    failed+=("$name")
  fi
done

printf '\n'
step "Summary"
ok "Installed/updated: ${#installed[@]}"
if [ ${#failed[@]} -gt 0 ]; then
  warn "Failed: ${failed[*]} (logs in cache/node-<name>.log)"
  exit 1
fi
