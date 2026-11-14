# Provisioning

Everything the demo needs at runtime comes from one dotenv file. This page
describes how to generate each value, how to mint the Bifrost virtual key, how to
release the export CronJob, and how to open the Cloudflare edge for a demo
window.

## The dotenv

The file is named by `services.aiidalab-openclaw-demo.secretsFile`. The default
is `/run/secrets/aiidalab-openclaw-demo.env`. `k3s-manifests` reads it as root at
activation and creates the Kubernetes Secrets from it.

Format rules:

- one `KEY=VALUE` per line;
- no quotes, no spaces around `=`, no `$` expansion;
- everything after the first `=` is the value, verbatim;
- `#` at the start of a line is a comment; empty lines are skipped;
- base64 values must be a single line.

Values are only read at activation. Editing the file does nothing until
`k3s-manifests` runs again, which happens on the next `nixos-rebuild switch`
(the file is a restart trigger) or when you restart the unit:

```bash
sudo systemctl restart k3s-manifests.service
```

## The 15 keys

| Key | Secret and key | Source |
|---|---|---|
| `AIIDA_DB_PASSWORD` | `aiidalab-db` / `POSTGRES_PASSWORD` | random |
| `AIIDA_RABBIT_PASSWORD` | `aiidalab-rabbitmq` / `RABBITMQ_PASSWORD` | random |
| `AIIDA_RABBIT_COOKIE` | `aiidalab-rabbitmq` / `RABBITMQ_ERLANG_COOKIE` | random |
| `AIIDA_JUPYTER_TOKEN` | `aiidalab-jupyter` / `JUPYTER_TOKEN` | random |
| `CLAW_GATEWAY_TOKEN` | `openclaw-gateway` / `OPENCLAW_GATEWAY_PASSWORD` | random |
| `AIIDA_SLURM_KEY_B64` | `aiidalab-slurm` / `id_ed25519` | new SSH private key, base64 |
| `AIIDA_SLURM_PUB` | `slurm-ssh` / `authorized_keys` | matching public key, plain text |
| `MUNGE_KEY_B64` | `munge-key` / `munge.key` | 1024 random bytes, base64 |
| `VERTEX_ADC_B64` | `vertex-credentials` / `credentials.json` | ADC JSON, base64 |
| `BIFROST_SETUP_TOKEN` | `bifrost-setup` / `token` | random |
| `BIFROST_VK` | `openclaw` / `bifrost-vk` | minted in Bifrost; may start empty |
| `AIIDA_MCP_TOKEN` | `aiida-mcp`, `aiida-mcp-client` / `token` | random; may start empty |
| `CLAW_TUNNEL_ACCOUNT_TAG` | `cloudflared-credentials` (`AccountTag`) | Cloudflare tunnel JSON |
| `CLAW_TUNNEL_ID` | `cloudflared-credentials` (`TunnelID`) | Cloudflare tunnel JSON |
| `CLAW_TUNNEL_SECRET` | `cloudflared-credentials` (`TunnelSecret`) | Cloudflare tunnel JSON |

The three `CLAW_TUNNEL_*` keys are needed only when `ingress.enable = true`.

## Random values

```bash
openssl rand -hex 32
```

Use one fresh value for each of `AIIDA_DB_PASSWORD`, `AIIDA_RABBIT_PASSWORD`,
`AIIDA_RABBIT_COOKIE`, `AIIDA_JUPYTER_TOKEN`, `CLAW_GATEWAY_TOKEN`,
`BIFROST_SETUP_TOKEN` and `AIIDA_MCP_TOKEN`. Hex is safe for every consumer,
including the Erlang cookie and the Jupyter token.

## SLURM SSH key pair

AiiDA connects to the SLURM controller as `aiida` with this key. The controller
trusts the public half.

```bash
ssh-keygen -t ed25519 -N '' -C aiida@slurm -f ./slurm_key
base64 -w0 ./slurm_key
cat ./slurm_key.pub
```

Put the base64 output in `AIIDA_SLURM_KEY_B64` and the single public line in
`AIIDA_SLURM_PUB`. Delete `./slurm_key` afterwards, or move it into your secret
store.

`base64 -w0` writes one line with no wrapping. Without `-w0`, GNU base64 breaks
the output at 76 characters and the dotenv reader cannot reassemble it.

## MUNGE key

Both SLURM pods authenticate RPC with munge and must hold the same key.

```bash
head -c 1024 /dev/urandom > munge.key
base64 -w0 munge.key
```

Put the output in `MUNGE_KEY_B64`. Rotation is handled: the `munged` supervisor
inside each pod watches the mounted key and restarts `munged` when it changes, so
a new key needs no hand-ordered pod restart.

## Vertex application default credentials

Bifrost reads `GOOGLE_APPLICATION_CREDENTIALS`, which points at
`/etc/gcp/credentials.json`, mounted from the `vertex-credentials` Secret.

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project my-gcp-project
gcloud services enable aiplatform.googleapis.com
```

Then encode the file:

```bash
base64 -w0 ~/.config/gcloud/application_default_credentials.json
```

Put the output in `VERTEX_ADC_B64`. Two credential shapes work from that path: an
`authorized_user` file from `application-default login`, and an
`external_account` file from workload identity federation.

`gcloud auth login` alone does not refresh application default credentials. A
stale ADC file produces a token-refresh error in the Bifrost log and in the
selftest job, while the pod itself runs normally. Regenerate the file and
update `VERTEX_ADC_B64` when that happens. The Bifrost pod must be restarted to
see a rotated Secret:

```bash
sudo k3s kubectl -n bifrost rollout restart deployment/bifrost
```

## Cloudflare tunnel values

Create the tunnel in the Cloudflare dashboard, then copy three fields from the
credentials JSON it gives you:

```json
{
    "AccountTag": "0123456789abcdef0123456789abcdef",
    "TunnelID": "00000000-0000-0000-0000-000000000000",
    "TunnelSecret": "AAAA..."
}
```

Put `AccountTag` in `CLAW_TUNNEL_ACCOUNT_TAG`, `TunnelID` in `CLAW_TUNNEL_ID` and
`TunnelSecret` in `CLAW_TUNNEL_SECRET`, as plain strings. The module assembles
the credentials JSON for the connector from these three values, so do not base64
them again.

## Bifrost virtual key

OpenClaw authenticates to Bifrost with a virtual key. Bifrost does not create one
by itself, and the admin API is locked until the setup token is presented. That
token is `BIFROST_SETUP_TOKEN`, already applied as the `bifrost-setup` Secret.

An empty `BIFROST_VK` is not fatal for the cluster, but OpenClaw cannot call any
model. On a fresh install the unit prints:

```text
WARNING: BIFROST_VK is unset and no bifrost-vk Secret exists; OpenClaw cannot call models
```

Mint the key:

1. Forward the gateway to the host:

    ```bash
    sudo k3s kubectl -n bifrost port-forward svc/bifrost 8080:8080
    ```

2. Start a setup session. The token is traded for a cookie that authenticates
    management calls for 12 hours:

    ```bash
    export BIFROST_SETUP_TOKEN='<value from the dotenv>'
    curl -sS -c /tmp/bifrost-cookies \
        -H "X-Bifrost-Setup-Token: $BIFROST_SETUP_TOKEN" \
        -X POST http://127.0.0.1:8080/api/session/setup
    ```

3. Create the key. `allow_all_providers` matters: without it and without
    `provider_configs`, the key is deny-by-default and calls no provider at all.

    ```bash
    curl -sS -b /tmp/bifrost-cookies \
        -H 'Content-Type: application/json' \
        -X POST http://127.0.0.1:8080/api/governance/virtual-keys \
        -d '{"name":"openclaw","allow_all_providers":true}'
    ```

4. Copy `virtual_key.value` from the response into `BIFROST_VK` in the dotenv.

5. Apply the Secret and restart the gateway. The gateway reads `BIFROST_VK` only
    at container start:

    ```bash
    sudo systemctl restart k3s-manifests.service
    sudo k3s kubectl -n openclaw rollout restart deployment/openclaw
    ```

If the second call answers `403`, your Bifrost version wants an admin account
first. Open the dashboard through the same forward (`http://127.0.0.1:8080`),
create the admin account with the setup token in the Setup token field, then
retry step 3 or create the key in the dashboard.

To verify the gateway path without OpenClaw, run the suspended selftest job:

```bash
sudo k3s kubectl -n bifrost patch job bifrost-selftest --type=merge \
    -p '{"spec":{"suspend":false}}'
sudo k3s kubectl -n bifrost logs job/bifrost-selftest
```

It calls `POST /v1/chat/completions` and prints the model id and token usage.

## Export CronJob

`40-aiidalab/82-export-cron.yaml` is held by default. It is a CronJob that runs
every 10 minutes, exports every terminal `CalcJob` whose checkpoint is stale into
`notebooks/<pk>-files/`, and keeps its state in
`$HOME/.aiida-files-export/checkpoint.json`, guarded by a `flock`. The MCP
on-demand export tool uses the same script and the same checkpoint, so the two
cannot interleave.

It is held because it rewrites trees that the MCP tool may already have written,
and because a demo usually wants exports to happen when the agent asks for them.

Release it with the option, then switch:

```nix
services.aiidalab-openclaw-demo.releaseExportCron = true;
```

```bash
sudo nixos-rebuild switch --flake .#demo
sudo k3s kubectl -n aiidalab get cronjob files-export
```

If a switch rendered the file but the unit did not finish, apply it from the
rendered tree. The manifest unit's script names that tree:

```bash
manifests=$(sudo grep -ho '/nix/store/[a-z0-9]*-aiidalab-openclaw-demo-manifests' \
    /nix/store/*-unit-script-k3s-manifests-start/bin/k3s-manifests-start | head -1)
sudo k3s kubectl apply -f "$manifests/40-aiidalab/82-export-cron.yaml"
```

Turning the option off does not delete the object. `kubectl apply` adds and
updates, it never prunes. Delete it explicitly:

```bash
sudo k3s kubectl -n aiidalab delete cronjob files-export
```

## Cloudflare edge

The edge is off by default. `ingress.enable = true` applies `70-edge` with a
closed configuration: `cloudflared` connects to Cloudflare, and its only ingress
rule is a catch-all 502, so no hostname serves anything. Opening hostnames is a
second, deliberate step, which is what keeps a demo from staying exposed.

Three hostnames are wired:

| Public hostname | Backend |
|---|---|
| `ingress.clawHostname` | `openclaw:18789`, the control UI |
| `ingress.aiidaHostname` | `aiidalab:8888`, Jupyter/AiiDAlab |
| `*.<ingress.portalDomain>` | `openclaw:18790`, per-session portals |

### Before enabling

1. Create the tunnel and put the three `CLAW_TUNNEL_*` values in the dotenv.
2. Set `ingress.credentialsFile` to the tunnel's credentials JSON path. The
    option is required when the edge is enabled; the connector's credential is
    built from the three dotenv values, so keep this file as their source.
3. Create a proxied CNAME for each explicit hostname pointing at
    `<tunnel-id>.cfargotunnel.com`, and a proxied wildcard CNAME for the portal
    domain.
4. Create one Access application per hostname pattern, including the wildcard,
    with an identity provider and a policy. Copy each application's audience tag
    into `ingress.audClaw`, `ingress.audAiida` and `ingress.audPortal`.
5. Set the edge options:

    ```nix
    services.aiidalab-openclaw-demo.ingress = {
        enable = true;
        clawHostname = "claw.example.com";
        aiidaHostname = "aiida.example.com";
        portalDomain = "example.com";
        tunnelId = "00000000-0000-0000-0000-000000000000";
        teamName = "example-team";
        audClaw = "<audience tag>";
        audAiida = "<audience tag>";
        audPortal = "<audience tag>";
        credentialsFile = "/run/secrets/cloudflare-tunnel.json";
    };
    ```

6. Switch. The module creates the connector Secret, applies the closed config,
    and rolls the connector.

The portal domain needs a certificate for the apex and exactly one wildcard
level: `<portal-domain>` and `*.<portal-domain>`. A deeper name such as
`*.portal.<zone>` is not covered by a standard Universal SSL certificate and the
TLS handshake fails at the edge.

An empty audience tag produces a route with no Access block. Protect that route
another way before opening it.

### Open a demo window

Two ConfigMaps describe the connector's routes: `cloudflared-ingress`, which is
closed, and `cloudflared-ingress-demo`, which carries the three routes. The
connector mounts the first. Copy the second into the first and restart the
connector:

```bash
sudo k3s kubectl -n edge get configmap cloudflared-ingress-demo \
    -o jsonpath='{.data.config\.yml}' > /tmp/cloudflared-open.yml
sudo k3s kubectl -n edge create configmap cloudflared-ingress \
    --from-file=config.yml=/tmp/cloudflared-open.yml --dry-run=client -o yaml \
    | sudo k3s kubectl apply -f -
sudo k3s kubectl -n edge rollout restart deployment/cloudflared
sudo k3s kubectl -n edge rollout status deployment/cloudflared
```

The demo ConfigMap was rendered with your own option values, which is why this
is the path to use. When `ingress.enable` is set, the module also installs an
`ingress-switch` command rendered from the same values:

```bash
sudo ingress-switch up
```

Check the three routes:

```bash
curl -sSI https://claw.example.com/
curl -sSI https://aiida.example.com/
curl -sSI https://portal-id.example.com/
```

Each returns `302` to the Access login while Access is configured. A `502` means
the closed configuration is still live.

### Close it again

```bash
sudo ingress-switch down
```

That writes the closed ConfigMap and restarts the connector. The module also
restores the tree on every activation:

```bash
sudo systemctl restart k3s-manifests.service
```

The unit reapplies the tree, which restores the closed ConfigMap, and rolls
`cloudflared` because the edge is enabled. Every hostname returns 502 again.

Leaving the tunnel connector running with the closed config is safe: it serves
nothing. Set `ingress.enable = false` and switch to remove the whole layer.
Nothing deletes the objects, so remove them by hand if you want them gone:

```bash
sudo k3s kubectl -n edge delete deployment/cloudflared
sudo k3s kubectl -n edge delete configmap cloudflared-ingress cloudflared-ingress-demo
sudo k3s kubectl -n edge delete secret cloudflared-credentials
```

## Checklist before the first switch

- 15 keys present, one `KEY=VALUE` per line, no quotes.
- `AIIDA_SLURM_PUB` is the public half of `AIIDA_SLURM_KEY_B64`.
- `MUNGE_KEY_B64` decodes to exactly 1024 bytes.
- `VERTEX_ADC_B64` decodes to valid JSON with a `type` field.
- `BIFROST_VK` is empty for the first boot; that is expected, and the minting
    step comes after the cluster is up.
- The file is mode 0600 and outside the Nix store.
