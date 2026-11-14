**THIS IS SLOP I MADE FOR A TECH DEMO, BEWARE!!!**

# AiiDAlab + OpenClaw demo

A NixOS module and flake that turns one machine into a single-node k3s cluster
and installs a demo stack: an OpenClaw agent, AiiDAlab on AiiDA, a rootless SLURM
cluster running Quantum ESPRESSO, a CPU cryo-EM submit host, and Bifrost as the
model gateway in front of Vertex AI. I built it to watch an agent work on real
cluster objects: submit a `pw.x` calculation through AiiDA, follow it through
SLURM, read the result, and write a notebook into AiiDAlab. Jobs run on the
cluster; nothing is simulated. The module owns k3s itself.

## Requirements

- NixOS with flakes enabled, and Docker on the host
    (`virtualisation.docker.enable = true`) for two of the four images.
- About 20 GB free for the image builds and imports. The claims request 206 GiB,
    but they are thin on `local-path`.
- Tens of minutes on the first activation. The AiiDAlab image installs three
    Python environments; the cryo-EM image installs RELION, CTFFIND and
    Pipeliner.
- A Google Cloud project with Vertex AI enabled and application default
    credentials. `vertex.project` is asserted, so evaluation fails without it.
- A node address the pods can reach. The OpenClaw egress policy needs it for the
    Kubernetes API path after DNAT.

## Install

Add the flake input, import `nixosModules.default`, and set the required options:

```nix
services.aiidalab-openclaw-demo = {
    enable = true;
    nodeAddress = "192.0.2.10";
    vertex.project = "my-gcp-project";
};
```

`storageClass` defaults to `local-path` and `secretsFile` to
`/run/secrets/aiidalab-openclaw-demo.env`. Fill that dotenv from
`secrets.env.example` first; it holds 15 keys and stays out of the Nix store. Do
not enable `services.k3s` yourself.

```bash
sudo nixos-rebuild switch --flake .#demo
```

The switch builds and imports the images, renders the manifests, and applies them
from a systemd unit. There is no registry and no manual `kubectl apply`. Then
forward port 18789 and open the control UI:

```bash
sudo k3s kubectl -n openclaw port-forward svc/openclaw 18789:18789
```

Log in with the password from the `openclaw-gateway` Secret. Verification steps
and first-run notes are in [docs/install.md](docs/install.md).

## Security

Nothing is published by default. Every Service is `ClusterIP`, k3s ships without
Traefik and ServiceLB, and the Cloudflare edge is opt-in and off, so a default
install is reachable only through `kubectl port-forward` on the host.

Every namespace enforces the restricted Pod Security Standard, and every pod runs
as a non-root uid with a read-only root filesystem. Every namespace starts from
default-deny on ingress and egress; the allowed paths are explicit and
namespace-scoped. The agent may only `get` pods and `create pods/exec` on three
named pods.

Secrets live in a root-only dotenv named by `secretsFile`, never in the Nix
store, and become Kubernetes Secrets at activation.

## Docs

- [docs/architecture.md](docs/architecture.md): components, namespaces, diagrams,
    delivery chain, secrets, policy.
- [docs/install.md](docs/install.md): options, switch, verify, port-forward.
- [docs/provisioning.md](docs/provisioning.md): secret values, Bifrost virtual
    key, export CronJob, Cloudflare edge.

## Scope

One node, one replica per service, local-path storage. The manifests are written
to make failures readable, not to survive load or run unattended.
