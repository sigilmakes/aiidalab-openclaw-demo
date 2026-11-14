#!/bin/bash
# Wait until the profile, PostgreSQL and RabbitMQ are reachable, then run the
# AiiDA daemon in the foreground.
set -euo pipefail
V=/opt/venvs/lab/bin

echo "[aiida-daemon] waiting for AiiDA profile + db + broker..."
for _ in $(seq 1 120); do
  if [ -f "$HOME/.aiida/config.json" ] \
     && python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); sys.exit(0 if s.connect_ex((sys.argv[1], int(sys.argv[2])))==0 else 1)" "$AIIDA_DB_HOST" "$AIIDA_DB_PORT" \
     && "$V/python" -c "import socket,sys; s=socket.socket(); s.settimeout(2); sys.exit(0 if s.connect_ex((sys.argv[1], int(sys.argv[2])))==0 else 1)" "$AIIDA_RABBITMQ_HOST" "$AIIDA_RABBITMQ_PORT"
  then
    break
  fi
  sleep 5
done
echo "[aiida-daemon] starting"
exec "$V/verdi" daemon start --foreground 2
