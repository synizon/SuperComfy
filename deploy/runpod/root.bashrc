# SuperComfy RunPod image shell setup. Baked to /root/.bashrc by
# deploy/runpod/Dockerfile; paths must match it.
export SUPERCOMFY_DIR=/opt/supercomfy
export PATH="$SUPERCOMFY_DIR/cache/venv/bin:/root/.local/bin:$PATH"

# Non-interactive shells stop here.
case "$-" in *i*) ;; *) return 0 ;; esac

cd "$SUPERCOMFY_DIR" 2>/dev/null || true
export PS1='\u@supercomfy:\w# '

alias comfy='cd /opt/supercomfy && ./run.sh'
alias comfy-stop="pkill -f 'main.py --listen'"

if [ -z "${SUPERCOMFY_BANNER_SHOWN:-}" ]; then
  export SUPERCOMFY_BANNER_SHOWN=1
  echo "SuperComfy RunPod image — repo at /opt/supercomfy"
  echo "  start: comfy   stop: comfy-stop   update: ./update.sh"
  echo "  nodes: ./downloadnodes.sh   models: ./downloadmodels.sh"
  echo "Dependencies are baked at cache/venv — do not run ./install.sh unless you mean to replace them."
fi
