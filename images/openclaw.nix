# Evaluated standalone so the flake input stays the only shared state: the
# gateway, its bundled node runtime and the runtime patch are replicated here
# instead of imported from the host service.
#
# Upstream node 24.22.1 segfaults when autoPatchelfHook patches the ELF
# interpreter before the RPATH (patchelf 0.19.2); the fix below and
# images/patch-runtime.py match the host OpenClaw wrapper exactly.
#
# manifests/60-openclaw references the sandbox.local/openclaw:<version>
# RepoTag built here, so `ctr images import` alone is enough; no registry is in
# the loop.
{
    pkgs,
    lib ? pkgs.lib,
    openclaw,
}:

let
    # The openclaw.json ConfigMap references sandbox.local/openclaw:<tag>;
    # assert keeps the image tag and the manifests in lockstep.
    gatewayVersion = "2026.10.7";

    node =
        if lib.versionAtLeast pkgs.nodejs_24.version "24.22.1" then
            pkgs.nodejs_24
        else
            (import "${openclaw}/nix/packages/nodejs-24.nix" {
                inherit (pkgs)
                    lib
                    stdenv
                    stdenvNoCC
                    fetchurl
                    autoPatchelfHook
                    bash
                    testers
                    nodejs_24
                    ;
            }).overrideAttrs (
                old: {
                    nativeBuildInputs = lib.filter (
                        p: (p.pname or p.name or "") != "auto-patchelf-hook"
                    ) (old.nativeBuildInputs or [ ]);
                    postFixup = ''
                        patchelf="${pkgs.patchelf}/bin/patchelf"
                        # Order matters: interpreter-then-RPATH grows the program headers
                        # twice and segfaults on first run (patchelf 0.19.2).
                        $patchelf --set-rpath "${
                            lib.makeLibraryPath [ pkgs.stdenv.cc.cc pkgs.stdenv.cc.cc.lib ]
                        }" "$out/bin/node"
                        $patchelf --set-interpreter "$(
                            cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker
                        )" "$out/bin/node"
                    '';
                }
            );

    # The patched node must be visible to the upstream overlay so the gateway
    # package, checks and plugin tooling all bind against the working runtime.
    openclawPkgs = import pkgs.path {
        inherit (pkgs.stdenv.hostPlatform) system;
        overlays = [
            (_final: _prev: { nodejs_24 = node; })
            openclaw.overlays.default
        ];
    };

    gatewayPkg = openclawPkgs.openclawPackages.openclaw-gateway.overrideAttrs (old: {
        # The npm install script never runs postInstall hooks.
        installPhase = ''
            ${old.installPhase}
            ${pkgs.python3}/bin/python3 ${./patch-runtime.py} "$out/lib/node_modules/openclaw"
        '';
    });

    # Shared libraries that pip wheels and non-Nix binaries expect. The Nix
    # Python packages carry their own RPATHs, but a venv built with pip wheels
    # still needs these on LD_LIBRARY_PATH.
    runtimeLibs = with pkgs; [
        stdenv.cc.cc.lib
        zlib
    ];

    python3Env = pkgs.python3.withPackages (ps: with ps; [
        numpy
        matplotlib
        pillow
        pandas
        ase
        requests
        pyyaml
        pip
    ]);

    # The worker's shell is the gateway container itself (sandbox.mode=off),
    # so this list is its entire toolchain. Keep the coding basics explicit:
    # the image previously carried only coreutils, git, curl, openssh and a
    # bare Python, which left grep/sed/awk/find, archives, jq and any plotting
    # library unavailable.
    deps = with pkgs; [
        bashInteractive
        coreutils
        findutils
        gnugrep
        gnused
        gawk
        gnutar
        gzip
        xz
        zip
        unzip
        jq
        yq-go
        sqlite
        diffutils
        patch
        file
        which
        tree
        less
        openssl
        wget
        rsync
        procps
        fontconfig
        git
        curl
        openssh
        ripgrep
        chromium
        nodejs_24
        uv
        nix
        kubectl
        python3Env
        python3
        cacert
        tzdata
        dejavu_fonts
    ] ++ runtimeLibs;

    # The image's own /nix/store is the only source of the gateway and Python
    # runtimes. A blank PVC over /nix would hide them, so the pod seeds a PVC
    # from this store and loads this registration file into the new store DB.
    nixpkgsSource = pkgs.runCommand "nixpkgs-source" { } ''
        mkdir -p $out
        cp -a ${pkgs.path}/. $out/
    '';

    imageContents = [
        gatewayPkg
        pkgs.dockerTools.binSh
        pkgs.dockerTools.usrBinEnv
    ] ++ deps ++ [ nixpkgsSource ];
    closure = pkgs.closureInfo { rootPaths = imageContents; };

    # A store database whose paths are the runtime /nix/store paths, not the
    # build sandbox's. The pod seeds it once and the gateway postStart hook
    # adds any paths introduced by a later image.
    nixDb = pkgs.runCommand "openclaw-nix-db" {
        nativeBuildInputs = [ pkgs.nix ];
    } ''
        mkdir -p $out/var/nix/profiles $out/var/nix/gcroots $out/var/nix/temproots
        export NIX_STATE_DIR=$out/var/nix
        export NIX_REMOTE=local
        nix-store --init
        nix-store --load-db < ${closure}/registration
    '';
in
assert (gatewayPkg.version or "") == gatewayVersion;

pkgs.dockerTools.buildLayeredImage {
    name = "sandbox.local/openclaw";
    tag = gatewayVersion;
    maxLayers = 255;
    contents = imageContents;
    extraCommands = ''
        [ -e bin/sh ] || ln -s /bin/bash bin/sh
        # The merged contents already provide share/fonts (from dejavu_fonts)
        # and bin/*; only the deterministic browser path needs an explicit link.
        # The gateway launches browsers at a fixed executablePath (see the
        # openclaw.json ConfigMap); PATH alone is not enough there.
        rm -f bin/chromium
        ln -s ${pkgs.chromium}/bin/chromium bin/chromium
        mkdir -p etc/fonts srv/openclaw tmp
        cat > etc/passwd <<'ESSID'
root:x:0:0:root:/root:/bin/sh
openclaw:x:10001:10001:OpenClaw:/tmp:/bin/sh
ESSID
        cat > etc/group <<'ESSID'
root:x:0:
openclaw:x:10001:
ESSID
        cat > etc/fonts/fonts.conf <<'ESSID'
${builtins.readFile ./fonts.conf}ESSID
        mkdir -p etc/nix nix/var/nix
        cp ${closure}/registration etc/nix/openclaw-registration
        cp -a ${nixDb}/var/nix/. nix/var/nix/
        cat > etc/nix/nix.conf <<'ESSID'
experimental-features = nix-command flakes
sandbox = false
build-users-group =
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
ESSID
    '';
    config = {
        Entrypoint = [ "${gatewayPkg}/bin/openclaw" ];
        Cmd = [
            "gateway"
            "run"
            "--bind"
            "custom"
            "--port"
            "18789"
            "--auth"
            "token"
        ];
        User = "10001:10001";
        WorkingDir = "/srv/openclaw";
        Env = [
            "PATH=${lib.makeBinPath deps}:/bin"
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "HOME=/srv/openclaw"
            "OPENCLAW_CONFIG_PATH=/etc/openclaw/openclaw.json"
            "OPENCLAW_CONFIG_READONLY=1"
            "OPENCLAW_STATE_DIR=/srv/openclaw"
            "OPENCLAW_LOG_DIR=/srv/openclaw/logs"
            "XDG_CACHE_HOME=/srv/openclaw/cache"
            "XDG_CONFIG_HOME=/srv/openclaw/config"
            "XDG_DATA_HOME=/srv/openclaw/data"
            # Matplotlib needs a writable cache and explicit fontconfig; both
            # live on the state PVC or in the image's /etc/fonts, never in the
            # read-only root filesystem.
            "MPLCONFIGDIR=/srv/openclaw/cache/matplotlib"
            "MPLBACKEND=Agg"
            "LD_LIBRARY_PATH=${lib.makeLibraryPath runtimeLibs}"
            "FONTCONFIG_FILE=/etc/fonts/fonts.conf"
            "FONTCONFIG_PATH=/etc/fonts"
            "PYTHONUNBUFFERED=1"
            "OPENCLAW_DISABLE_BONJOUR=1"
            "LC_ALL=C.UTF-8"
            "NIX_PATH=nixpkgs=${nixpkgsSource}"
            "TMPDIR=/srv/openclaw/tmp/nix"
        ];
    };
    meta.description = "OpenClaw gateway ${gatewayVersion} for the sandbox cluster";
}
