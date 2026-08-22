# Baked to /root/.jupyter/ by deploy/runpod/Dockerfile.
# Login shells so JupyterLab terminals get /root/.bashrc (PATH, aliases).
c.ServerApp.terminado_settings = {"shell_command": ["/bin/bash", "--login"]}
