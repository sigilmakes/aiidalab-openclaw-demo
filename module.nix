{ config, lib, pkgs, openclawFlake ? null, ... }:

let
    cfg = config.services.aiidalab-openclaw-demo;
    inherit (lib) mkEnableOption mkIf mkOption mkDefault optional optionalString types;

    kubeconfig = "/etc/rancher/k3s/k3s.yaml";

    openclawImage = pkgs.callPackage ./images/openclaw.nix { openclaw = openclawFlake; };
    slurmImage = pkgs.callPackage ./images/slurm.nix { };

    imageRefs = {
        openclaw = "sandbox.local/openclaw:2026.10.7";
        slurm = "sandbox.local/slurm:26.05.5";
        cryoem = "sandbox.local/cryoem:1.6.1";
        aiidalab = "sandbox.local/aiidalab:26.10.0";
    };

    sha = builtins.hashString "sha256";
    aiidalabHash = builtins.substring 0 16 (sha (builtins.concatStringsSep "" (map builtins.readFile [
        ./images/aiidalab/Dockerfile
        ./images/aiidalab/requirements-lab.lock
        ./images/aiidalab/requirements-qe.lock
        ./images/aiidalab/requirements-agents.lock
    ])));
    cryoemHash = builtins.substring 0 16 (sha (builtins.readFile ./images/cryoem/Dockerfile));

    hold =
        optional (!cfg.releaseExportCron) "40-aiidalab/82-export-cron.yaml"
        ++ optional (!cfg.ingress.enable) "70-edge";

    site = {
        STORAGE_CLASS = cfg.storageClass;
        NODE_ADDRESS = cfg.nodeAddress;
        CLAW_HOSTNAME = cfg.ingress.clawHostname;
        AIIDA_HOSTNAME = cfg.ingress.aiidaHostname;
        PORTAL_DOMAIN = cfg.ingress.portalDomain;
        TUNNEL_ID = cfg.ingress.tunnelId;
        ACCESS_TEAM = cfg.ingress.teamName;
        ACCESS_AUD_CLAW = cfg.ingress.audClaw;
        ACCESS_AUD_AIIDA = cfg.ingress.audAiida;
        ACCESS_AUD_PORTAL = cfg.ingress.audPortal;
        VERTEX_PROJECT = cfg.vertex.project;
        VERTEX_REGION_CLAUDE = cfg.vertex.regionClaude;
        VERTEX_REGION_GEMINI = cfg.vertex.regionGemini;
    };

    manifests = import ./nix/render.nix { inherit pkgs; } {
        source = ./manifests;
        inherit hold;
        substitutions = site;
        openclawImage = openclawImage;
    };

    applyOrder =
        [ "10-network-policy.yaml" "20-storage.yaml" "35-slurm" "40-aiidalab" "50-bifrost" "60-openclaw" ]
        ++ optional cfg.ingress.enable "70-edge";

    cloudflaredSecret =
        if cfg.ingress.credentialsFile != null then
            ''kubectl -n edge create secret generic cloudflared-credentials --from-file=credentials.json=${cfg.ingress.credentialsFile} --dry-run=client -o yaml | kubectl apply -f -''
        else
            ''kubectl -n edge create secret generic cloudflared-credentials --from-file=credentials.json="$tmp/cloudflared.json" --dry-run=client -o yaml | kubectl apply -f -'';

    secrets = {
        openclaw-gateway = ''kubectl -n openclaw create secret generic openclaw-gateway --from-literal=OPENCLAW_GATEWAY_PASSWORD="$CLAW_GATEWAY_TOKEN" --dry-run=client -o yaml | kubectl apply -f -'';
        aiidalab-db = ''kubectl -n aiidalab create secret generic aiidalab-db --from-literal=POSTGRES_PASSWORD="$AIIDA_DB_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -'';
        aiidalab-rabbitmq = ''kubectl -n aiidalab create secret generic aiidalab-rabbitmq --from-literal=RABBITMQ_PASSWORD="$AIIDA_RABBIT_PASSWORD" --from-literal=RABBITMQ_ERLANG_COOKIE="$AIIDA_RABBIT_COOKIE" --dry-run=client -o yaml | kubectl apply -f -'';
        aiidalab-jupyter = ''kubectl -n aiidalab create secret generic aiidalab-jupyter --from-literal=JUPYTER_TOKEN="$AIIDA_JUPYTER_TOKEN" --dry-run=client -o yaml | kubectl apply -f -'';
        slurm = ''
            kubectl -n aiidalab create secret generic aiidalab-slurm --from-file=id_ed25519="$tmp/id_ed25519" --dry-run=client -o yaml | kubectl apply -f -
            kubectl -n slurm create secret generic munge-key --from-file=munge.key="$tmp/munge.key" --dry-run=client -o yaml | kubectl apply -f -
            kubectl -n slurm create secret generic slurm-ssh --from-file=authorized_keys="$tmp/authorized_keys" --dry-run=client -o yaml | kubectl apply -f -'';
        vertex = ''kubectl -n bifrost create secret generic vertex-credentials --from-file=credentials.json="$tmp/vertex.json" --dry-run=client -o yaml | kubectl apply -f -'';
        bifrost = ''kubectl -n bifrost create secret generic bifrost-setup --from-literal=token="$BIFROST_SETUP_TOKEN" --dry-run=client -o yaml | kubectl apply -f -'';
    };

    secretSteps = with secrets;
        [ openclaw-gateway aiidalab-db aiidalab-rabbitmq aiidalab-jupyter slurm vertex bifrost ]
        ++ optional cfg.ingress.enable cloudflaredSecret;
in
{
    options.services.aiidalab-openclaw-demo = {
        enable = mkEnableOption "the AiiDALab, SLURM, Bifrost and OpenClaw demo on a local k3s cluster";

        nodeAddress = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "192.168.1.10";
            description = ''
                Address the k3s API serves on. The OpenClaw egress policy needs it:
                kube-router evaluates egress after DNAT, so allowing the 10.43.0.1
                Service address alone is not enough for kubectl exec.
            '';
        };

        storageClass = mkOption {
            type = types.str;
            default = "local-path";
            description = "StorageClass for the demo claims. k3s ships local-path; any RWO class works on a single node.";
        };

        secretsFile = mkOption {
            type = types.path;
            default = "/run/secrets/aiidalab-openclaw-demo.env";
            description = ''
                Runtime dotenv with the keys listed in secrets.env.example. Read only
                by the root manifest unit; never stored in the Nix store.
            '';
        };

        releaseExportCron = mkOption {
            type = types.bool;
            default = false;
            description = ''
                Apply 40-aiidalab/82-export-cron.yaml. It is held by default because
                it rewrites notebooks/<pk>-files/ for every terminal CalcJob whose
                exporter checkpoint is stale, and that tree may have been written by
                the MCP tool instead.
            '';
        };

        hardenHostFirewall = mkOption {
            type = types.bool;
            default = true;
            description = ''
                Drop VXLAN (8472), kubelet (10250) and the API (6443) from lanSubnet,
                and trust the CNI links. Only effective when the host runs the NixOS
                iptables firewall; disable it when the host uses another firewall.
            '';
        };

        lanSubnet = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "192.168.1.0/24";
            description = "Subnet the hardening rules drop from. Unset means no drop rules are added.";
        };

        vertex = {
            project = mkOption {
                type = types.str;
                default = "";
                example = "my-gcp-project";
                description = "Google Cloud project that serves the Bifrost Vertex models.";
            };
            regionClaude = mkOption {
                type = types.str;
                default = "europe-west1";
                description = "Vertex region for the Claude models.";
            };
            regionGemini = mkOption {
                type = types.str;
                default = "europe-west2";
                description = "Vertex region for the Gemini models.";
            };
        };

        ingress = {
            enable = mkEnableOption "the Cloudflare tunnel edge";

            clawHostname = mkOption { type = types.str; default = "claw.example.com"; };
            aiidaHostname = mkOption { type = types.str; default = "aiida.example.com"; };
            portalDomain = mkOption { type = types.str; default = "example.com"; };
            tunnelId = mkOption { type = types.str; default = "00000000-0000-0000-0000-000000000000"; };
            teamName = mkOption { type = types.str; default = "example-team"; };
            audClaw = mkOption { type = types.str; default = "0000000000000000000000000000000000000000000000000000000000000000"; };
            audAiida = mkOption { type = types.str; default = "0000000000000000000000000000000000000000000000000000000000000000"; };
            audPortal = mkOption { type = types.str; default = "0000000000000000000000000000000000000000000000000000000000000000"; };

            credentialsFile = mkOption {
                type = types.nullOr types.path;
                default = null;
                description = ''
                    cloudflared tunnel credentials JSON (AccountTag, TunnelID,
                    TunnelSecret). When set, the module mounts this file instead of
                    building the JSON from the three CLAW_TUNNEL_* dotenv keys.
                '';
            };
        };
    };

    config = mkIf cfg.enable {
        assertions = [
            { assertion = openclawFlake != null; message = "services.aiidalab-openclaw-demo needs the flake's openclaw input; import nixosModules.default rather than module.nix directly."; }
            { assertion = cfg.nodeAddress != null; message = "services.aiidalab-openclaw-demo.nodeAddress must be set to the node's address."; }
            { assertion = cfg.vertex.project != ""; message = "services.aiidalab-openclaw-demo.vertex.project must be set for Bifrost."; }
            {
                assertion = cfg.nodeAddress == null || builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" cfg.nodeAddress != null;
                message = "services.aiidalab-openclaw-demo.nodeAddress must be an IPv4 address.";
            }
        ];

        boot.kernelModules = [ "br_netfilter" "overlay" ];
        boot.kernel.sysctl = {
            "net.ipv4.ip_forward" = 1;
            "net.bridge.bridge-nf-call-iptables" = 1;
        };

        services.k3s = {
            enable = true;
            role = "server";
            clusterInit = true;
            disable = [ "traefik" "servicelb" ];
            extraFlags = [
                "--secrets-encryption"
                "--write-kubeconfig-mode=0600"
                "--kubelet-arg=address=127.0.0.1"
            ];
        };

        environment.systemPackages = mkIf cfg.ingress.enable [
            (pkgs.callPackage ./packages/ingress-switch.nix { inherit manifests; })
        ];

        networking.firewall.trustedInterfaces =
            mkIf (cfg.hardenHostFirewall && config.networking.firewall.enable) [ "cni0" "flannel.1" ];
        networking.firewall.extraInputRules = mkIf
            (cfg.hardenHostFirewall && config.networking.firewall.enable && cfg.lanSubnet != null)
            (lib.mkAfter ''
                ip saddr ${cfg.lanSubnet} udp dport 8472 drop
                ip saddr ${cfg.lanSubnet} tcp dport 10250 drop
                ip saddr ${cfg.lanSubnet} tcp dport 6443 drop
            '');

        systemd.services.k3s-images = {
            description = "Import flake-built images into the k3s containerd store";
            after = [ "k3s.service" ];
            requires = [ "k3s.service" ];
            wantedBy = [ "multi-user.target" ];
            restartTriggers = [ openclawImage slurmImage ];
            serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
            };
            script = ''
                set -euo pipefail
                ${pkgs.k3s}/bin/k3s ctr images import ${openclawImage}
                ${pkgs.k3s}/bin/k3s ctr images import ${slurmImage}
                for ref in ${lib.escapeShellArg imageRefs.openclaw} ${lib.escapeShellArg imageRefs.slurm}; do
                    ${pkgs.k3s}/bin/k3s ctr images ls -q \
                        | ${pkgs.gnugrep}/bin/grep -Fqx "$ref" \
                        || { echo "image $ref did not import" >&2; exit 1; }
                done
            '';
        };

        systemd.services.k3s-cryoem-image = {
            description = "Build and import the CPU cryo-EM image";
            after = [ "docker.service" "k3s.service" ];
            requires = [ "docker.service" "k3s.service" ];
            before = [ "k3s-manifests.service" ];
            wantedBy = [ "multi-user.target" ];
            restartTriggers = [ ./images/cryoem/Dockerfile ];
            path = with pkgs; [ docker k3s coreutils gnugrep ];
            serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                TimeoutStartSec = "60min";
            };
            script = ''
                set -euo pipefail
                stamp=/var/lib/aiidalab-openclaw-demo-cryoem.stamp
                if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "${cryoemHash}" ]; then
                    exit 0
                fi
                docker build -t ${imageRefs.cryoem} ${./images/cryoem}
                tmp=$(mktemp)
                trap 'rm -f "$tmp"' EXIT
                docker save ${imageRefs.cryoem} -o "$tmp"
                k3s ctr images import "$tmp"
                printf '%s\n' "${cryoemHash}" > "$stamp"
            '';
        };

        systemd.services.k3s-aiidalab-image = {
            description = "Build and import the AiiDAlab stack image";
            after = [ "docker.service" "k3s.service" ];
            requires = [ "docker.service" "k3s.service" ];
            before = [ "k3s-manifests.service" ];
            wantedBy = [ "multi-user.target" ];
            restartTriggers = [
                ./images/aiidalab/Dockerfile
                ./images/aiidalab/requirements-lab.lock
                ./images/aiidalab/requirements-qe.lock
                ./images/aiidalab/requirements-agents.lock
            ];
            path = with pkgs; [ docker k3s coreutils gnugrep ];
            serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                TimeoutStartSec = "60min";
            };
            script = ''
                set -euo pipefail
                stamp=/var/lib/aiidalab-openclaw-demo-aiidalab.stamp
                if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "${aiidalabHash}" ]; then
                    exit 0
                fi
                docker build -t ${imageRefs.aiidalab} ${./images/aiidalab}
                tmp=$(mktemp)
                trap 'rm -f "$tmp"' EXIT
                docker save ${imageRefs.aiidalab} -o "$tmp"
                k3s ctr images import "$tmp"
                printf '%s\n' "${aiidalabHash}" > "$stamp"
            '';
        };

        systemd.services.k3s-manifests = {
            description = "Apply the demo cluster manifests";
            after = [ "k3s.service" "k3s-images.service" "k3s-cryoem-image.service" "k3s-aiidalab-image.service" ];
            requires = [ "k3s.service" ];
            wants = [ "k3s-images.service" "k3s-cryoem-image.service" "k3s-aiidalab-image.service" ];
            wantedBy = [ "multi-user.target" ];
            restartTriggers = [ manifests cfg.secretsFile ];
            serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
            };
            script = ''
                set -euo pipefail
                export KUBECONFIG=${kubeconfig}
                for _ in $(seq 1 30); do
                    ${pkgs.kubectl}/bin/kubectl get --raw /readyz >/dev/null 2>&1 && break
                    sleep 2
                done

                ${pkgs.kubectl}/bin/kubectl apply -f ${manifests}/00-namespaces.yaml

                for ref in ${lib.escapeShellArg imageRefs.openclaw} ${lib.escapeShellArg imageRefs.slurm} \
                           ${lib.escapeShellArg imageRefs.cryoem} ${lib.escapeShellArg imageRefs.aiidalab}; do
                    ${pkgs.k3s}/bin/k3s ctr images ls -q \
                        | ${pkgs.gnugrep}/bin/grep -Fqx "$ref" \
                        || echo "WARNING: $ref missing from the containerd store" >&2
                done

                while IFS='=' read -r key val; do
                    [ -z "$key" ] && continue
                    case "$key" in \#*) continue ;; esac
                    export "$key=$val"
                done < ${cfg.secretsFile}

                tmp=$(mktemp -d /run/aiidalab-openclaw-demo-secrets.XXXXXX)
                trap 'rm -rf "$tmp"' EXIT
                printf %s "$AIIDA_SLURM_KEY_B64" | ${pkgs.coreutils}/bin/base64 -d > "$tmp/id_ed25519"
                printf %s "$MUNGE_KEY_B64" | ${pkgs.coreutils}/bin/base64 -d > "$tmp/munge.key"
                printf '%s\n' "$AIIDA_SLURM_PUB" > "$tmp/authorized_keys"
                printf %s "$VERTEX_ADC_B64" | ${pkgs.coreutils}/bin/base64 -d > "$tmp/vertex.json"
                ${optionalString (cfg.ingress.enable && cfg.ingress.credentialsFile == null) ''
                printf '{"AccountTag":"%s","TunnelID":"%s","TunnelSecret":"%s"}\n' \
                    "$CLAW_TUNNEL_ACCOUNT_TAG" "$CLAW_TUNNEL_ID" "$CLAW_TUNNEL_SECRET" > "$tmp/cloudflared.json"
                ''}
                chmod 600 "$tmp"/*

                ${lib.concatStringsSep "\n" secretSteps}

                # Bifrost virtual key. On a fresh install it has to be minted in
                # Bifrost first; an empty value keeps whatever Secret exists.
                if [ -n "''${BIFROST_VK:-}" ]; then
                    ${pkgs.kubectl}/bin/kubectl -n openclaw create secret generic bifrost-vk \
                        --from-literal=BIFROST_VK="$BIFROST_VK" --dry-run=client -o yaml | ${pkgs.kubectl}/bin/kubectl apply -f -
                elif ! ${pkgs.kubectl}/bin/kubectl -n openclaw get secret bifrost-vk >/dev/null 2>&1; then
                    echo "WARNING: BIFROST_VK is unset and no bifrost-vk Secret exists; OpenClaw cannot call models" >&2
                fi

                # MCP bearer token: installs may omit it. Keep the live
                # value, otherwise generate one.
                MCP_TOKEN="''${AIIDA_MCP_TOKEN:-}"
                if [ -z "$MCP_TOKEN" ]; then
                    MCP_TOKEN=$(${pkgs.kubectl}/bin/kubectl -n aiidalab get secret aiida-mcp \
                        -o jsonpath='{.data.token}' 2>/dev/null | ${pkgs.coreutils}/bin/base64 -d || true)
                fi
                if [ -z "$MCP_TOKEN" ]; then
                    MCP_TOKEN=$(${pkgs.openssl}/bin/openssl rand -hex 32)
                fi
                printf %s "$MCP_TOKEN" > "$tmp/mcp-token"
                chmod 600 "$tmp/mcp-token"
                ${pkgs.kubectl}/bin/kubectl -n aiidalab create secret generic aiida-mcp \
                    --from-file=token="$tmp/mcp-token" --dry-run=client -o yaml | ${pkgs.kubectl}/bin/kubectl apply -f -
                ${pkgs.kubectl}/bin/kubectl -n openclaw create secret generic aiida-mcp-client \
                    --from-file=token="$tmp/mcp-token" --dry-run=client -o yaml | ${pkgs.kubectl}/bin/kubectl apply -f -

                ${lib.concatMapStrings (d: ''
                ${pkgs.kubectl}/bin/kubectl apply -f ${manifests}/${d}
                '') applyOrder}

                ${optionalString cfg.ingress.enable ''
                ${pkgs.kubectl}/bin/kubectl -n edge rollout restart deployment/cloudflared
                ${pkgs.kubectl}/bin/kubectl -n edge rollout status deployment/cloudflared --timeout=180s
                ''}
            '';
        };
    };
}
