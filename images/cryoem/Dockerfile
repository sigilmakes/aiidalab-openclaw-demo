# syntax=docker/dockerfile:1
#
# CPU-only CCP-EM Pipeliner + RELION + CTFFIND4 + Slurm client
# ---------------------------------------------------------------------------
# Base: Debian bookworm-slim (glibc 2.36). Chosen over:
#   * the Nix slurm image + conda: Nix glibc (2.44) is fine for ABI, but conda
#     binaries expect /lib64/ld-linux-x86-64.so.2 at a standard path, which a
#     Nix-store-only image does not provide -> needs an FHS shim/patchelf (fragile).
#   * Nix source builds: nixpkgs has no relion/ctffind/pipeliner; writing 3 new
#     derivations is the most fragile and time-consuming path.
# ---------------------------------------------------------------------------

# ------------------------------ builder ------------------------------------
FROM debian:bookworm-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf automake libtool pkg-config \
      cmake make gcc g++ \
      curl ca-certificates xz-utils bzip2 \
      zlib1g-dev libbz2-dev libssl-dev \
      libreadline-dev libncurses-dev libpam0g-dev \
      libhwloc-dev libdbus-1-dev liblz4-dev \
    && rm -rf /var/lib/apt/lists/*

# --- munge 0.5.18 (matches the existing cluster: munge-0.5.18) ---
WORKDIR /build
RUN curl -fsSL -o munge.tar.xz \
      https://github.com/dun/munge/releases/download/munge-0.5.18/munge-0.5.18.tar.xz \
    && tar -xJf munge.tar.xz \
    && cd munge-0.5.18 \
    && ./configure --prefix=/opt/munge --sysconfdir=/opt/munge/etc \
    && make -j"$(nproc)" \
    && make install \
    && rm -rf /build/munge-0.5.18 /build/munge.tar.xz

# --- slurm 26.05.5 (client + slurmd + slurmctld, for submit/compute use) ---
WORKDIR /build
RUN curl -fsSL -o slurm.tar.bz2 \
      https://download.schedmd.com/slurm/slurm-26.05.5.tar.bz2 \
    && tar -xjf slurm.tar.bz2 \
    && cd slurm-26.05.5 \
    && ./configure --prefix=/opt/slurm --sysconfdir=/opt/slurm/etc --with-munge=/opt/munge \
    && make -j"$(nproc)" \
    && make install \
    && rm -rf /build/slurm-26.05.5 /build/slurm.tar.bz2

# --- CTFFIND 4.1.14 (prebuilt static binary, CPU; free academic licence) ---
WORKDIR /build
RUN mkdir -p /opt/ctffind/bin \
    && curl -fsSL "https://grigoriefflab.umassmed.edu/system/tdf?path=ctffind-4.1.14-linux64.tar.gz&file=1" -o ctffind.tar.gz \
    && tar -xzf ctffind.tar.gz -C /opt/ctffind \
    && chmod +x /opt/ctffind/bin/ctffind \
    && rm -f ctffind.tar.gz

# --- micromamba + conda env: python 3.12, RELION 5.1.1 (CPU), pipeliner ---
RUN mkdir -p /opt/micromamba && cd /opt/micromamba \
    && curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xj bin/micromamba

ENV MAMBA_ROOT_PREFIX=/opt/conda
ENV MAMBA_NO_BANNER=1

RUN /opt/micromamba/bin/micromamba create -y -p /opt/conda/envs/cryoem \
      -c conda-forge -c bioconda \
      python=3.12 pip relion=5.1.1 \
    && /opt/conda/envs/cryoem/bin/pip install --no-cache-dir "ccpem-pipeliner==1.6.1"

# ------------------------------ runtime ------------------------------------
FROM debian:bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl bash procps passwd tar \
      libreadline8 libtinfo6 libpam0g libncursesw6 zlib1g \
      libhwloc15 libdbus-1-3 liblz4-1 libssl3 libcurl4 libsystemd0 \
      libgomp1 libbz2-1.0 libnuma1 openssh-client \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/munge   /opt/munge
COPY --from=builder /opt/slurm   /opt/slurm
COPY --from=builder /opt/ctffind /opt/ctffind
COPY --from=builder /opt/conda   /opt/conda

RUN printf '/opt/munge/lib\n/opt/slurm/lib\n/opt/conda/envs/cryoem/lib\n' > /etc/ld.so.conf.d/cryoem.conf \
    && ldconfig

# Config/keys are mounted at runtime, not baked in.
RUN mkdir -p /etc/slurm /etc/munge /var/run/munge /data \
    && groupadd -g 1000 cryoem \
    && useradd -u 1000 -g 1000 -m -s /bin/bash cryoem \
    && chown -R 1000:1000 /var/run/munge /data /home/cryoem

ENV PATH="/opt/conda/envs/cryoem/bin:/opt/ctffind/bin:/opt/slurm/bin:/opt/slurm/sbin:/opt/munge/bin:/opt/munge/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    CONDA_PREFIX="/opt/conda/envs/cryoem" \
    PIPELINER_CTFFIND_EXECUTABLE="/opt/ctffind/bin/ctffind" \
    SLURM_CONF="/etc/slurm/slurm.conf" \
    MUNGE_SOCKET_DIR="/var/run/munge" \
    OMPI_ALLOW_RUN_AS_ROOT="1" \
    OMPI_ALLOW_RUN_AS_ROOT_CONFIRM="1"

RUN printf 'export PATH="%s"\n' "$PATH" > /etc/profile.d/cryoem.sh \
    && chmod 644 /etc/profile.d/cryoem.sh

USER 1000:1000
WORKDIR /data

CMD ["/bin/bash"]
