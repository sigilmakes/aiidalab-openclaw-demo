# Install

This page takes a NixOS host from nothing to a working demo. It assumes you
already manage the host with flakes.

## 0. Prerequisites

- NixOS with `nix.settings.experimental-features = [ "nix-command" "flakes" ]`.
- Docker enabled. The module builds two images with the host Docker daemon:
    ```nix
    virtualisation.docker.enable = true;
    ```
- Free disk: about 20 GB for the Nix build, the Docker build and the four
    imported images, plus whatever the PersistentVolumeClaims fill. The claims
    request 206 GiB in total and are thin on `local-path`.
- A Google Cloud project with the Vertex AI API enabled, and application
    default credentials for an account that may call the models.
- The node's address on the network. Pods need it to reach the Kubernetes API.

The module enables `services.k3s` itself, so do not enable k3s separately on the
same host.

## 1. Add the flake input

```nix
{
    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
        aiidalab-openclaw-demo.url = "git+https://example.com/aiidalab-openclaw-demo.git";
    };

    outputs = { self, nixpkgs, aiidalab-openclaw-demo, ... }: {
        nixosConfigurations.demo = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
                aiidalab-openclaw-demo.nixosModules.default
                ./hosts/demo.nix
            ];
        };
    };
}
```

Import `nixosModules.default`, not `module.nix`. The module needs the flake's
pinned OpenClaw source and asserts that it is present.

## 2. Set the options

```nix
{
    services.aiidalab-openclaw-demo = {
        enable = true;
        nodeAddress = "192.0.2.10";
        storageClass = "local-path";
        secretsFile = "/run/secrets/aiidalab-openclaw-demo.env";
        vertex = {
            project = "my-gcp-project";
            regionClaude = "europe-west1";
            regionGemini = "europe-west2";
        };
    };
}
```

Options that matter for a first install:

| Option | Default | Meaning |
|---|---|---|
| `enable` | false | Turn the demo on |
| `nodeAddress` | null | Address the k3s API serves on. Required: the OpenClaw egress policy needs it after DNAT |
| `storageClass` | `"local-path"` | Class for every claim. Any RWO class works on one node |
| `secretsFile` | `/run/secrets/aiidalab-openclaw-demo.env` | Runtime dotenv. Never in the Nix store |
| `vertex.project` | `""` | Google Cloud project for the Bifrost Vertex models. Required, and non-empty |
| `vertex.regionClaude` | `europe-west1` | Vertex region for the Claude models |
| `vertex.regionGemini` | `europe-west2` | Vertex region for the Gemini models |
| `releaseExportCron` | false | Apply the files-export CronJob |
| `hardenHostFirewall` | true | Trust the CNI links and drop VXLAN, kubelet and the API from `lanSubnet` |
| `lanSubnet` | null | Subnet the drop rules apply to. Unset means no drop rules |
| `ingress.enable` | false | Apply the Cloudflare tunnel edge |

If you set `lanSubnet`, use the network the host is on, for example
`"192.0.2.0/24"`. If the host uses a firewall other than the NixOS iptables
one, set `hardenHostFirewall = false`.

## 3. Put the dotenv in place

Write the file named by `secretsFile` before the first switch. The manifest unit
runs during activation and fails without it.

```bash
sudo install -d -m 0755 /run/secrets
sudo install -m 0600 /dev/null /run/secrets/aiidalab-openclaw-demo.env
sudoedit /run/secrets/aiidalab-openclaw-demo.env
```

Start from `secrets.env.example` in this repository. The file format is strict:
one `KEY=VALUE` per line, no quotes, no spaces around `=`, no shell
substitution. Lines starting with `#` and empty lines are skipped. Values are
read verbatim.

`/run` is a tmpfs, so this file disappears on reboot. Either recreate it from
your secret store in a boot-time unit, or point `secretsFile` at a path that
survives. Do not commit a filled copy.

Generation commands for all 15 keys are in
[provisioning.md](provisioning.md). `BIFROST_VK` is the one value you cannot
generate locally: it must be minted in Bifrost, and the first boot runs without
it.

## 4. Switch

```bash
sudo nixos-rebuild switch --flake .#demo
```

The first activation does the heavy work: it builds the OpenClaw and SLURM
images with Nix, builds the AiiDAlab and cryo-EM images with Docker, imports all
four into containerd, and then applies the manifests. Expect tens of minutes.
Later switches reuse the image builds until their inputs change.

Watch the units:

```bash
sudo systemctl status k3s-images.service
sudo systemctl status k3s-aiidalab-image.service
sudo systemctl status k3s-cryoem-image.service
sudo systemctl status k3s-manifests.service
sudo journalctl -u k3s-manifests.service -b
```

## 5. Verify

```bash
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
sudo k3s ctr images ls | grep sandbox.local
```

Expected images: `sandbox.local/openclaw:2026.10.7`,
`sandbox.local/slurm:26.05.5`, `sandbox.local/cryoem:1.6.1`,
`sandbox.local/aiidalab:26.10.0`.

Expected pods, one replica each:

| Namespace | Pods |
|---|---|
| `aiidalab` | `aiidalab-postgres-0`, `aiidalab-rabbitmq-0`, `aiidalab-jupyter-*`, `aiida-daemon-*`, `aiida-ops-0`, `aiida-mcp-*` |
| `slurm` | `slurmctld-0`, `slurmd-*`, `cryoem-ops-0` |
| `bifrost` | `bifrost-*` |
| `openclaw` | `openclaw-*` |

Then check the one job that proves the compute path:

```bash
sudo k3s kubectl -n slurm get job slurm-selftest
sudo k3s kubectl -n slurm logs job/slurm-selftest
```

The log ends with `SELFTEST OK`. It shows `sinfo`, a munge round-trip, a batch
job that ran on `compute01`, and `QE_PW_X_OK` from a `pw.x` presence check.

The AiiDA bootstrap job should be `Complete`:

```bash
sudo k3s kubectl -n aiidalab get jobs -l app=aiidalab-bootstrap
sudo k3s kubectl -n aiidalab logs job/<job-name>
```

A completed job prints `bootstrap complete`. It is safe to re-run; every step is
guarded.

## 6. Port-forward the two web UIs

The kubeconfig is written 0600 to `/etc/rancher/k3s/k3s.yaml`, so run the client
as root or copy the file to a directory your user can read.

OpenClaw control UI, port 18789:

```bash
sudo k3s kubectl -n openclaw port-forward svc/openclaw 18789:18789
```

Open `http://127.0.0.1:18789` and log in with the gateway password:

```bash
sudo k3s kubectl -n openclaw get secret openclaw-gateway \
    -o jsonpath='{.data.OPENCLAW_GATEWAY_PASSWORD}' | base64 -d; echo
```

Jupyter/AiiDAlab, port 8888:

```bash
sudo k3s kubectl -n aiidalab port-forward svc/aiidalab 8888:8888
```

Open `http://127.0.0.1:8888/lab/tree/notebooks` and paste the token:

```bash
sudo k3s kubectl -n aiidalab get secret aiidalab-jupyter \
    -o jsonpath='{.data.JUPYTER_TOKEN}' | base64 -d; echo
```

Links that the MCP tools return are built from `ingress.aiidaHostname`, so they
open only when that hostname is served. With the edge off, navigate to
`notebooks/` in the file browser instead of following those links.

Portals, when you need one, are the third forward:

```bash
sudo k3s kubectl -n openclaw port-forward svc/openclaw 18790:18790
```

`kubectl port-forward` is served by the kubelet and reaches the pod from the
node. The policies here are written for cluster traffic, so a forward normally
works; if your CNI blocks it, use `kubectl exec` inside the pod or open the edge
from [provisioning.md](provisioning.md).

## First-run notes

**The gateway takes minutes to become ready.** Its startup probe allows 8
minutes and the pod uses the `Recreate` strategy, so a new pod waits for the old
one to drain its sessions. Do not stack rollouts; wait for the first to finish.

**The control UI checks its origin.** `openclaw.json` sets `publicOrigin` and
`controlUi.allowedOrigins` from `ingress.clawHostname`, which defaults to
`https://claw.example.com`. A port-forward serves `http://127.0.0.1:18789`, a
different origin. If the UI refuses to load, set `ingress.clawHostname` to the
hostname you actually use and reach the UI through that name, or add the local
origin to `allowedOrigins` in `manifests/60-openclaw/10-configmap.yaml` while
testing.

**OpenClaw cannot call models without a Bifrost virtual key.** An empty
`BIFROST_VK` leaves the Secret absent on a fresh install, and
`k3s-manifests` prints a warning. Mint the key, put it in the dotenv, re-run the
manifest unit, and restart the deployment. The steps are in
[provisioning.md](provisioning.md#bifrost-virtual-key).

**The export CronJob is held.** `releaseExportCron` defaults to false, so
`40-aiidalab/82-export-cron.yaml` is not applied. The MCP server's on-demand
export tool writes retrieved files to `notebooks/<pk>-files/` without it.

**The Bifrost selftest is suspended.** Run it by hand when you want to prove the
Vertex path:

```bash
sudo k3s kubectl -n bifrost patch job bifrost-selftest --type=merge \
    -p '{"spec":{"suspend":false}}'
sudo k3s kubectl -n bifrost logs job/bifrost-selftest
```

A `200` with a model id and token usage means the gateway reached Vertex. A
token-refresh error means the ADC file is stale; regenerate `VERTEX_ADC_B64`.

**Nothing is published to the network.** All Services are `ClusterIP` and the
edge is off. See [provisioning.md](provisioning.md#cloudflare-edge) before you
open a hostname.

## Changing things later

| Change | Effect |
|---|---|
| Edit the dotenv | `k3s-manifests` re-runs on the next switch and updates the Secrets |
| Edit `manifests/` | The rendered tree changes, the unit re-runs, and the checksums roll the affected pods |
| Edit a Dockerfile or lock file | The stamp changes, so the image is rebuilt and reimported |
| Change `openclawFlake` | A new image derivation triggers a rebuild and a gateway rollout |
| Rotate a Secret by hand | Restart the consuming pod. Pods read Secrets only at container start |
