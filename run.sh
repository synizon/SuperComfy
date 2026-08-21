#!/usr/bin/env bash
# SuperComfy launcher: attention/speed selector, password protection via Caddy,
# optional token-protected JupyterLab, then ComfyUI in the foreground.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=supercomfy/lib/common.sh
source "$SCRIPT_DIR/supercomfy/lib/common.sh"

RESELECT=0
for arg in "$@"; do
  case "$arg" in
    --select) RESELECT=1 ;;
    -h|--help)
      echo "Usage: ./run.sh [--select]"
      echo "  --select   re-open the attention/speed selector (choice is saved in .env)"
      exit 0 ;;
    *) die "Unknown option: $arg (try --help)" ;;
  esac
done

banner "Run"
load_env

[ -x "$VENV_PY" ] && [ -f "$COMFY_DIR/main.py" ] || die "SuperComfy is not installed yet — run ./install.sh first"
if [ -f "$VENV_DIR/.installed" ] && [ "$(cat "$VENV_DIR/.installed")" != "$(requirements_hash)" ]; then
  warn "ComfyUI's requirements changed since the last install — run ./install.sh to refresh"
fi
cuda_wheel_gate

# --- attention / speed selector ---------------------------------------------
py_has() { "$VENV_PY" -c "import $1" >/dev/null 2>&1; }

if [ -z "${COMFY_ATTENTION:-}" ] || [ "$RESELECT" -eq 1 ]; then
  if [ -t 0 ]; then
    step "Speed / quality preset"
    has_sage=0; has_flash=0; has_ck=0
    py_has sageattention && has_sage=1
    py_has flash_attn && has_flash=1
    py_has comfy_kitchen && has_ck=1
    avail() { [ "$1" -eq 1 ] && printf '' || printf ' %s(not installed)%s' "$C_DIM" "$C_RESET"; }
    printf '  1) pytorch        — default cross-attention, always works\n'
    printf '  2) sage           — SageAttention 2.2, fastest on RTX 30xx+%b\n' "$(avail $has_sage)"
    printf '  3) flash          — FlashAttention 2%b\n' "$(avail $has_flash)"
    printf '  4) comfy-kitchen  — Comfy-Org optimized kernels%b\n' "$(avail $has_ck)"
    read -rp "  Choose [1-4] (default 1): " choice
    case "${choice:-1}" in
      2) [ "$has_sage" -eq 1 ] || die "SageAttention is not installed — re-run ./install.sh with nvcc available"
         COMFY_ATTENTION=sage ;;
      3) [ "$has_flash" -eq 1 ] || die "flash-attn is not installed"
         COMFY_ATTENTION=flash ;;
      4) [ "$has_ck" -eq 1 ] || die "comfy-kitchen is not installed"
         COMFY_ATTENTION=comfy-kitchen ;;
      *) COMFY_ATTENTION=pytorch ;;
    esac
    read -rp "  Enable --fast optimizations (fp16 accumulation etc.)? [y/N]: " fast
    case "${fast:-n}" in y|Y) COMFY_FAST=1 ;; *) COMFY_FAST=0 ;; esac
    save_env COMFY_ATTENTION "$COMFY_ATTENTION"
    save_env COMFY_FAST "$COMFY_FAST"
  else
    COMFY_ATTENTION="${COMFY_ATTENTION:-pytorch}" COMFY_FAST="${COMFY_FAST:-0}"
  fi
fi

comfy_args=()
case "$COMFY_ATTENTION" in
  sage)          comfy_args+=(--use-sage-attention) ;;
  flash)         comfy_args+=(--use-flash-attention) ;;
  comfy-kitchen) comfy_args+=(--use-ck-attention) ;;
  pytorch|*)     comfy_args+=(--use-pytorch-cross-attention) ;;
esac
[ "${COMFY_FAST:-0}" = "1" ] && comfy_args+=(--fast)
ok "Attention: $COMFY_ATTENTION$([ "${COMFY_FAST:-0}" = "1" ] && echo ' + --fast')"

# --- ports & bind ------------------------------------------------------------
PUBLIC_PORT="${COMFY_PORT:-8188}"
port_free "$PUBLIC_PORT" || die "Port $PUBLIC_PORT is already in use — is ComfyUI already running?"

# On RunPod (or whenever a password is set) expose to the network; else stay local.
if [ -n "${COMFY_BIND_HOST:-}" ]; then
  BIND_HOST="$COMFY_BIND_HOST"
elif [ -n "${COMFY_AUTH:-}" ] || [ -n "${RUNPOD_POD_ID:-}" ]; then
  BIND_HOST="0.0.0.0"
else
  BIND_HOST="127.0.0.1"
fi
if [ "$BIND_HOST" != "127.0.0.1" ] && [ -z "${COMFY_AUTH:-}" ] && [ "${SUPERCOMFY_INSECURE:-0}" != "1" ]; then
  die "Refusing to expose ComfyUI on $BIND_HOST without a password.
    Set COMFY_AUTH=yourpassword in .env (or SUPERCOMFY_INSECURE=1 to override)."
fi

# --- Caddy basic-auth front (only when a password is set) --------------------
CADDY_PID="" JUPYTER_PID=""
cleanup() {
  [ -n "$CADDY_PID" ] && kill "$CADDY_PID" 2>/dev/null
  [ -n "$JUPYTER_PID" ] && kill "$JUPYTER_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT INT TERM

ensure_caddy() {
  CADDY_BIN="$BIN_DIR/caddy"
  [ -x "$CADDY_BIN" ] && return 0
  step "Downloading Caddy (auth proxy)"
  mkdir -p "$BIN_DIR"
  curl -fsSL -o "$CADDY_BIN" \
    "https://caddyserver.com/api/download?os=linux&arch=amd64" \
    || die "Caddy download failed"
  chmod +x "$CADDY_BIN"
}

if [ -n "${COMFY_AUTH:-}" ]; then
  ensure_caddy
  INTERNAL_PORT="$(pick_port 18188)" || die "No free internal port near 18188"
  COMFY_BIND="127.0.0.1" COMFY_LISTEN_PORT="$INTERNAL_PORT"
  hash_pw="$("$CADDY_BIN" hash-password --plaintext "$COMFY_AUTH")"
  cat > "$CACHE_DIR/Caddyfile" <<EOF
{
	admin off
	auto_https off
}
http://:$PUBLIC_PORT {
	basic_auth {
		comfy $hash_pw
	}
	reverse_proxy 127.0.0.1:$INTERNAL_PORT
}
EOF
  "$CADDY_BIN" run --config "$CACHE_DIR/Caddyfile" --adapter caddyfile \
    >"$CACHE_DIR/caddy.log" 2>&1 &
  CADDY_PID=$!
  ok "Password protection on port $PUBLIC_PORT (user: comfy)"
else
  COMFY_BIND="$BIND_HOST" COMFY_LISTEN_PORT="$PUBLIC_PORT"
fi

# --- JupyterLab (optional) ---------------------------------------------------
if [ "${JUPYTER_ENABLE:-0}" = "1" ] || [ -n "${RUNPOD_POD_ID:-}" ]; then
  if py_has jupyterlab; then
    JPORT="${JUPYTER_PORT:-8888}"
    if port_free "$JPORT"; then
      token="${JUPYTER_TOKEN:-$("$VENV_PY" -c 'import secrets; print(secrets.token_hex(24))')}"
      nohup "$VENV_DIR/bin/jupyter" lab --no-browser --allow-root \
        --ip 0.0.0.0 --port "$JPORT" \
        --ServerApp.token="$token" \
        --ServerApp.root_dir=/ \
        --ServerApp.preferred_dir="$SUPERCOMFY_ROOT" \
        >"$CACHE_DIR/jupyterlab.log" 2>&1 &
      JUPYTER_PID=$!
      ok "JupyterLab on port $JPORT (token: $token)"
    else
      warn "Port $JPORT busy — JupyterLab already running?"
    fi
  else
    warn "JUPYTER_ENABLE=1 but JupyterLab is not installed — run SUPERCOMFY_JUPYTER=1 ./install.sh"
  fi
fi

# --- launch ------------------------------------------------------------------
printf '\n'
step "ComfyUI is starting"
if [ -n "${RUNPOD_POD_ID:-}" ]; then
  ok "Open: ${C_BOLD}https://${RUNPOD_POD_ID}-${PUBLIC_PORT}.proxy.runpod.net${C_RESET}"
else
  ok "Open: ${C_BOLD}http://127.0.0.1:${PUBLIC_PORT}${C_RESET}"
fi
[ -n "${COMFY_AUTH:-}" ] && ok "Login: user ${C_BOLD}comfy${C_RESET}, your COMFY_AUTH password"
printf '\n'

# shellcheck disable=SC2086  # COMFY_EXTRA_ARGS is a deliberate word-split list
exec_or_run() { cd "$COMFY_DIR" && "$VENV_PY" main.py \
  --listen "$COMFY_BIND" --port "$COMFY_LISTEN_PORT" \
  "${comfy_args[@]}" ${COMFY_EXTRA_ARGS:-}; }
exec_or_run
