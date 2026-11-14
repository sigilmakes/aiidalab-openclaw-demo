{ pkgs, manifests }:

let
    openConfig = "${manifests}/70-edge/cloudflared-demo.yaml";
    closedConfig = "${manifests}/70-edge/cloudflared.yaml";
in
pkgs.writeShellApplication {
    name = "ingress-switch";
    runtimeInputs = [
        pkgs.coreutils
        pkgs.kubectl
        pkgs.yq-go
    ];
    meta.description = "Copy the demo or catch-all cloudflared ingress config into the live edge ConfigMap";
    text = ''
        if [ "$#" -ne 1 ]; then
            echo "usage: ingress-switch up|down" >&2
            exit 2
        fi

        case "$1" in
            up) source_file=${openConfig} ;;
            down) source_file=${closedConfig} ;;
            *)
                echo "usage: ingress-switch up|down" >&2
                exit 2
                ;;
        esac

        config=$(mktemp)
        trap 'rm -f "$config"' EXIT
        yq -r 'select(.kind == "ConfigMap") | .data."config.yml"' "$source_file" > "$config"
        if [ ! -s "$config" ]; then
            echo "no config.yml in $source_file" >&2
            exit 1
        fi

        kubectl -n edge create configmap cloudflared-ingress \
            --from-file=config.yml="$config" --dry-run=client -o yaml \
            | kubectl apply -f -

        kubectl -n edge rollout restart deployment/cloudflared
        kubectl -n edge rollout status deployment/cloudflared --timeout=180s
    '';
}
