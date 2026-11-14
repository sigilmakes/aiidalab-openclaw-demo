#!/bin/bash
# Idempotent AiiDA bootstrap for the aiidalab namespace on the sandbox cluster.
# Creates (or verifies): AiiDA profile `aiidalab` (PostgreSQL psql_dos), RabbitMQ
# broker config, computer `slurm-local` (SSH + SLURM to the in-cluster slurm
# namespace), one code per Quantum ESPRESSO executable the installed plugin has a
# CalcJob for, and the SSSP 1.3 PBE/efficiency pseudopotential family installed
# from the archive baked into the image (no network needed).
# Secrets come from the cluster (created at activation from the runtime dotenv),
# never from here.
# Safe to re-run; every step is guarded.
set -euo pipefail
V="${AIIDA_VENV:-/opt/venvs/lab}/bin"

PROFILE_NAME="${AIIDA_PROFILE_NAME:-aiidalab}"
DB_HOST="${AIIDA_DB_HOST:-aiidalab-postgres}"
DB_PORT="${AIIDA_DB_PORT:-5432}"
DB_NAME="${AIIDA_DB_NAME:-aiidadb}"
DB_USER="${AIIDA_DB_USER:-aiida}"
: "${AIIDA_DB_PASSWORD:?AIIDA_DB_PASSWORD must be set (secret aiidalab-db)}"
: "${AIIDA_RABBITMQ_PASSWORD:?AIIDA_RABBITMQ_PASSWORD must be set (secret aiidalab-rabbitmq)}"

export AIIDA_RABBITMQ_HOST="${AIIDA_RABBITMQ_HOST:-aiidalab-rabbitmq}"
export AIIDA_RABBITMQ_PORT="${AIIDA_RABBITMQ_PORT:-5672}"
export AIIDA_RABBITMQ_VHOST="${AIIDA_RABBITMQ_VHOST:-/}"
export AIIDA_PROFILE_NAME="$PROFILE_NAME"

SLURM_SSH_USER=${SLURM_SSH_USER:-aiida}
SLURM_SSH_HOST=${SLURM_SSH_HOST:-slurm.slurm.svc.cluster.local}
SLURM_WORKDIR=${SLURM_WORKDIR:-/scratch/aiida}
QE_BIN=${QE_BIN:-/opt/qe/bin}

log() { echo "[aiidalab-bootstrap] $(date -u +%FT%TZ) $*"; }

# --- 0. stage the SSH key with permissions OpenSSH/paramiko accept ------------
# /run/secrets/id_ed25519 is the aiidalab-slurm secret (created from the runtime
# dotenv), mounted 0440; it is re-installed owner-only (0400) into $HOME/.ssh on
# the home PVC.
mkdir -p "$HOME/.ssh"
if [ -f /run/secrets/id_ed25519 ]; then
  install -m 0400 /run/secrets/id_ed25519 "$HOME/.ssh/id_ed25519"
else
  log "WARN: /run/secrets/id_ed25519 not mounted; SSH key not staged"
fi

# --- 0b. pin the slurm sshd host key at runtime (idempotent merge) ------------
touch "$HOME/.ssh/known_hosts"
if command -v ssh-keyscan >/dev/null 2>&1; then
  if ssh-keyscan -T 5 -t ed25519,ecdsa,rsa -p 22 "$SLURM_SSH_HOST" > /tmp/slurm-keyscan 2>/dev/null; then
    { grep -v "^${SLURM_SSH_HOST}[[:space:]]" "$HOME/.ssh/known_hosts" 2>/dev/null || true; \
      cat /tmp/slurm-keyscan; } | sort -u > "$HOME/.ssh/known_hosts.tmp"
    mv "$HOME/.ssh/known_hosts.tmp" "$HOME/.ssh/known_hosts"
    log "staged host keys for $SLURM_SSH_HOST"
  else
    log "WARN: ssh-keyscan failed for $SLURM_SSH_HOST; sshd may not be up yet"
  fi
fi

# --- 1. wait for postgres ----------------------------------------------------
log "waiting for ${DB_HOST}:${DB_PORT}..."
for _ in $(seq 1 60); do
  if python3 - "$DB_HOST" "$DB_PORT" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(2)
sys.exit(0 if s.connect_ex((sys.argv[1], int(sys.argv[2]))) == 0 else 1)
PY
  then break; fi
  sleep 5
done
log "postgres reachable"

# --- 2. profile (idempotent) --------------------------------------------------
# Contract guard: if `verdi profile show` succeeds, profile setup must not re-run.
if "$V/verdi" -p "$PROFILE_NAME" profile show >/dev/null 2>&1; then
  log "profile $PROFILE_NAME already set up"
else
  log "creating profile $PROFILE_NAME"
  "$V/verdi" profile setup core.psql_dos \
    --non-interactive \
    -p "$PROFILE_NAME" \
    --set-as-default \
    --email "aiida@example.org" \
    --first-name AiiDA \
    --last-name User \
    --institution "AiiDAlab Sandbox" \
    --broker core.rabbitmq \
    --database-engine postgresql_psycopg2 \
    --database-hostname "$DB_HOST" \
    --database-port "$DB_PORT" \
    --database-username "$DB_USER" \
    --database-password "$AIIDA_DB_PASSWORD" \
    --database-name "$DB_NAME" \
    --repository-uri "file://${AIIDA_REPOSITORY_DIR:-/home/aiida/aiida/repository}"
  if ! "$V/verdi" -p "$PROFILE_NAME" profile show >/dev/null 2>&1; then
    log "ERROR: profile creation did not succeed"
    exit 1
  fi
fi

# Broker parameters: separate command, they are not arguments of profile setup.
log "configuring broker for $PROFILE_NAME"
"$V/verdi" -p "$PROFILE_NAME" profile configure-broker core.rabbitmq \
  --non-interactive \
  --force \
  --broker-protocol amqp \
  --broker-host "$AIIDA_RABBITMQ_HOST" \
  --broker-port "$AIIDA_RABBITMQ_PORT" \
  --broker-username aiida \
  --broker-password "$AIIDA_RABBITMQ_PASSWORD" \
  --broker-virtual-host "${AIIDA_RABBITMQ_VHOST#/}"


# --- 3. in-cluster SLURM computer (idempotent) --------------------------------
if "$V/verdi" -p "$PROFILE_NAME" computer show slurm-local >/dev/null 2>&1; then
  log "computer slurm-local already exists"
else
  log "creating computer slurm-local"
  "$V/verdi" -p "$PROFILE_NAME" computer setup \
    --non-interactive \
    -L slurm-local \
    -D "In-cluster SLURM (k3s slurm namespace; partitions debug/batch; compute01, 8 CPUs)" \
    -H "$SLURM_SSH_HOST" \
    -T core.ssh \
    -S core.slurm \
    -w "$SLURM_WORKDIR"
fi
"$V/verdi" -p "$PROFILE_NAME" computer show slurm-local >/dev/null
log "configuring computer slurm-local SSH transport (idempotent overwrite)"
"$V/verdi" -p "$PROFILE_NAME" computer configure core.ssh \
  --non-interactive \
  --username "$SLURM_SSH_USER" \
  --port 22 \
  --key-filename "$HOME/.ssh/id_ed25519" \
  --timeout 60 \
  --compress \
  --load-system-host-keys \
  --key-policy RejectPolicy \
  --safe-interval 20 \
  slurm-local

# --- 4. QE codes (idempotent) -------------------------------------------------
# One code per Quantum ESPRESSO executable that aiida-quantumespresso exposes as a
# CalcJob. The image links every QE binary into /opt/qe/bin, so each of them runs
# through the same SSH/SLURM computer. Entries are <executable>:<default plugin>.
QE_CODES=(
    "pw.x:quantumespresso.pw"
    "cp.x:quantumespresso.cp"
    "ph.x:quantumespresso.ph"
    "pp.x:quantumespresso.pp"
    "dos.x:quantumespresso.dos"
    "projwfc.x:quantumespresso.projwfc"
    "bands.x:quantumespresso.bands"
    "matdyn.x:quantumespresso.matdyn"
    "q2r.x:quantumespresso.q2r"
    "neb.x:quantumespresso.neb"
    "pw2wannier90.x:quantumespresso.pw2wannier90"
    "pw2gw.x:quantumespresso.pw2gw"
    "open_grid.x:quantumespresso.open_grid"
)
for entry in "${QE_CODES[@]}"; do
    label="${entry%%:*}"
    plugin="${entry#*:}"
    if "$V/verdi" -p "$PROFILE_NAME" code show "$label" >/dev/null 2>&1; then
        log "code $label already exists"
        continue
    fi
    log "creating code $label ($plugin)"
    "$V/verdi" -p "$PROFILE_NAME" code create core.code.installed \
        --non-interactive \
        --label "$label" \
        --description "Quantum ESPRESSO $label on the in-cluster SLURM (shared /opt/qe)" \
        --computer slurm-local \
        --filepath-executable "$QE_BIN/$label" \
        --default-calc-job-plugin "$plugin" \
        --with-mpi
done

# --- 5. SSSP pseudopotential family (idempotent, offline) ----------------------
# The SSSP tarball is baked into the image at /opt/aiidalab; install runs with
# --from-download so the job never needs Materials Cloud network access.
SSSP_LABEL="SSSP/${AIIDA_SSSP_VERSION:-1.3}/${AIIDA_SSSP_FUNCTIONAL:-PBE}/${AIIDA_SSSP_PROTOCOL:-efficiency}"
if ! "$V/aiida-pseudo" -p "$PROFILE_NAME" list 2>/dev/null | grep -q "$SSSP_LABEL"; then
  log "installing SSSP family $SSSP_LABEL from baked archive (offline)"
  "$V/aiida-pseudo" -p "$PROFILE_NAME" install sssp \
    --version "${AIIDA_SSSP_VERSION:-1.3}" \
    --functional "${AIIDA_SSSP_FUNCTIONAL:-PBE}" \
    --protocol "${AIIDA_SSSP_PROTOCOL:-efficiency}" \
    --from-download "/opt/aiidalab/SSSP_1.3_PBE_efficiency.aiida_pseudo"
else
  log "SSSP family $SSSP_LABEL already installed"
fi

log "bootstrap complete; run 'verdi -p $PROFILE_NAME computer test slurm-local' once the slurm namespace is reachable"

