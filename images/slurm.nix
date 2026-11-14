# SLURM mini-cluster image for the the sandbox cluster (namespace: slurm).
#
# One image serves both roles: the controller (StatefulSet slurmctld: munged +
# slurmctld + sshd, port 2222) and the compute node (Deployment slurmd with
# hostname fixed to compute01). manifests/35-slurm references this exact tag.
#
# Consumed by the parent as:
#   pkgs.callPackage ./aiidalab-openclaw-demo/images/slurm.nix { }
# The output is a CRI-importable docker archive whose RepoTag is
# sandbox.local/slurm:26.05.5; the flake wiring must use that exact
# cfg.images key. Bump slurmTag here and in 35-slurm manifests together.
#
# Everything in this image runs as a non-root uid because the namespace
# enforces the restricted Pod Security Standard:
#   munge    uid 998 (munged process user)
#   slurm    uid 997 (declared for parity with host installs; unused by the
#                     daemons here)
#   aiida    uid 1000 (sshd runs AS this user, so ssh sessions and every
#                     SLURM job are uid 1000 with no setuid anywhere)
#
# Three constraints discovered by a host-level non-root experiment and baked
# into the manifests (see 35-slurm/00-slurm-conf.yaml):
#   - rootless slurmd (SlurmdUser) requires "CgroupPlugin=disabled" in
#     cgroup.conf, because the default v2 plugin would try to create a
#     systemd scope under /sys/fs/cgroup and abort slurmd startup;
#   - the munge socket path must match AuthInfo in slurm.conf
#     (/var/munge-rt/munge/munge.socket.2); libmunge ignores MUNGE_SOCKET;
#   - munged needs --key-file/--seed-file/--pid-file/--log-file flags: the
#     compiled-in defaults under /etc/munge and /var/log are not writable.
{
    pkgs,
    lib ? pkgs.lib,
}:

let
    slurmTag = "26.05.5";

    qe = pkgs.quantum-espresso;

    deps = with pkgs; [
        slurm
        munge
        openssh
        coreutils
        bashInteractive
        gnugrep
        gawk
        gnused
        openmpi
        hostname
    ];
in
pkgs.dockerTools.buildLayeredImage {
    name = "sandbox.local/slurm";
    tag = slurmTag;
    maxLayers = 255;
    contents = deps ++ [
        qe # explicit contents entry: the /opt/qe/bin links point into the closure
        pkgs.dockerTools.binSh
        pkgs.dockerTools.usrBinEnv
    ];
    extraCommands = ''
        # One flat /bin with everything on the image PATH. sshd exec sessions
        # do not inherit the image PATH; sshd_config sets PATH=/bin via SetEnv.
        IFS=:
        for d in ${lib.makeBinPath deps}; do
            for b in "$d"/*; do
                [ -e "bin/''${b##*/}" ] || ln -s "$b" "bin/''${b##*/}"
            done
        done
        mkdir -p opt/qe/bin etc/slurm var/munge-rt var/spool/slurmctld var/spool/slurmd var/lib/slurm home/aiida scratch tmp
        chmod 1777 tmp
        # Stable AiiDA code path: the whole QE bin dir, symlinked in place.
        for b in ${qe}/bin/*; do
            ln -s "$b" "opt/qe/bin/''${b##*/}"
        done
        cat > etc/passwd <<'ESSID'
root:x:0:0:root:/root:/bin/bash
munge:x:998:998:MUNGE:/var/munge-rt:/bin/false
slurm:x:997:997:SLURM:/var/spool/slurm:/bin/false
aiida:x:1000:1000:AiiDA:/home/aiida:/bin/bash
ESSID
        cat > etc/group <<'ESSID'
root:x:0:
munge:x:998:
slurm:x:997:
aiida:x:1000:
ESSID
    '';
    config = {
        Entrypoint = [ "/bin/bash" ];
        User = "1000:1000";
        WorkingDir = "/scratch/aiida";
        Env = [
            "PATH=/bin"
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "HOME=/home/aiida"
            "LC_ALL=C.UTF-8"
        ];
    };
    meta.description = "SLURM ${slurmTag} + QE 7.5 sandbox image for the sandbox cluster";
}
