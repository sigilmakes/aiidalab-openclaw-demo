# AiiDAlab stack image for the sandbox cluster (namespace aiidalab).
# Pinned python 3.12 base; three isolated virtualenvs because upstream pins
# conflict (resolver-proven, see swarm report):
#   /opt/venvs/lab    : aiida-core 2.9.4 + aiida-quantumespresso 5.1.0 +
#                       aiidalab 26.10.0 + jupyterlab (jupyter + verdi + daemon)
#   /opt/venvs/agents : aiida-agents @ 28314e79b4cfcc218a08bd3ec31ef44ce0e7278f
#                       + mcp-proxy 0.13.0 (runs the MCP bridge)
#   /opt/venvs/qe     : aiidalab-qe 26.6.5 + aiida-quantumespresso 4.12.1
#                       (registered as the `aiidalab-qe` ipykernel)
# plus the SSSP v1.3 PBE/efficiency pseudopotential archive baked for offline
# install, because the aiidalab namespace has no internet egress.
FROM python:3.12-slim@sha256:aa943ce411423c7582288f18707ff66eddcbaeb510502d747a72aeb34f30d159 AS builder
# gcc keeps sdist-only packages (e.g. PyCifRW) installable under uv.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates build-essential \
 && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.13.1 /uv /usr/local/bin/uv
COPY requirements-lab.lock requirements-agents.lock requirements-qe.lock /tmp/locks/

RUN set -eux; \
    uv venv /opt/venvs/lab \
 && uv pip install --no-deps --python /opt/venvs/lab/bin/python -r /tmp/locks/requirements-lab.lock \
 && uv venv /opt/venvs/agents \
 && uv pip install --no-deps --python /opt/venvs/agents/bin/python -r /tmp/locks/requirements-agents.lock \
 && uv venv /opt/venvs/qe \
 && uv pip install --no-deps --python /opt/venvs/qe/bin/python -r /tmp/locks/requirements-qe.lock

# Bake the SSSP bundle (`aiida-pseudo install sssp --download-only` output) so
# the bootstrap job installs the family with --from-download, offline. The
# bundle tarball itself embeds mtimes (md5 varies), so the server-published
# checksums of the inner archive and metadata are verified instead.
RUN set -eux; \
    mkdir -p /tmp/sssp /tmp/sssp-check \
 && cd /tmp/sssp \
 && /opt/venvs/lab/bin/aiida-pseudo install sssp \
       --version 1.3 --functional PBE --protocol efficiency --download-only \
 && tar -xf SSSP_1.3_PBE_efficiency.aiida_pseudo -C /tmp/sssp-check \
 && echo 'a58f1b3373f330179fd0832c48bb9a52  /tmp/sssp-check/archive.tar.gz' | md5sum -c - \
 && echo '3153c4b20fc90a44fba0236627525644  /tmp/sssp-check/metadata.json' | md5sum -c -

FROM python:3.12-slim@sha256:aa943ce411423c7582288f18707ff66eddcbaeb510502d747a72aeb34f30d159

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-client tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venvs /opt/venvs
COPY --from=builder /tmp/sssp/SSSP_1.3_PBE_efficiency.aiida_pseudo /opt/aiidalab/SSSP_1.3_PBE_efficiency.aiida_pseudo

RUN install -d -o 1000 -g 0 /home/aiida \
 && echo "aiida:x:1000:0::/home/aiida:/bin/bash" >> /etc/passwd

COPY aiidalab-entry.sh /usr/local/bin/aiidalab-entry.sh
COPY aiidalab-daemon.sh /usr/local/bin/aiidalab-daemon.sh
COPY bootstrap.sh /opt/aiidalab/bootstrap.sh
COPY jupyter_server_config.py  /etc/jupyter/jupyter_server_config.py
COPY kernels/aiidalab-qe/kernel.json /usr/local/share/jupyter/kernels/aiidalab-qe/kernel.json
RUN chmod 0755 /usr/local/bin/aiidalab-entry.sh /usr/local/bin/aiidalab-daemon.sh /opt/aiidalab/bootstrap.sh \
 && chmod 0644 /opt/aiidalab/SSSP_1.3_PBE_efficiency.aiida_pseudo /etc/jupyter/jupyter_server_config.py

USER 1000:0
WORKDIR /home/aiida
ENV HOME=/home/aiida \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    XDG_CACHE_HOME=/tmp/cache \
    XDG_CONFIG_HOME=/tmp/config \
    XDG_DATA_HOME=/tmp/data \
    JUPYTER_RUNTIME_DIR=/tmp/jupyter-runtime \
    MPLCONFIGDIR=/tmp/mpl \
    PATH=/opt/venvs/lab/bin:/opt/venvs/agents/bin:/opt/venvs/qe/bin:$PATH

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/aiidalab-entry.sh"]
CMD ["jupyter", "lab", "--ip", "0.0.0.0", "--port", "8888", "--no-browser", "--config", "/etc/jupyter/jupyter_server_config.py"]
