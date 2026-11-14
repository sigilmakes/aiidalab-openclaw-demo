#!/bin/bash
# Common entrypoint: stage the SSH key (created from the runtime dotenv) for the
# in-cluster SLURM host (0440 in the secret volume -> owner-only copy in
# $HOME/.ssh), then exec the container command. Host keys are pinned at runtime
# by the bootstrap job (ssh-keyscan), not baked, because the slurm sshd is
# deployed by a sibling.
set -euo pipefail
if [ -f /run/secrets/id_ed25519 ]; then
  install -D -m 0400 /run/secrets/id_ed25519 "$HOME/.ssh/id_ed25519"
fi
exec "$@"
