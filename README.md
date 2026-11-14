**THIS IS SLOP I MADE FOR A TECH DEMO, BEWARE!!!**

# AiiDAlab + OpenClaw demo

A NixOS module and a flake. It turns one machine into a single-node k3s cluster
and installs a demo stack into it: an OpenClaw agent, AiiDAlab with an AiiDA
profile, a rootless SLURM cluster that runs Quantum ESPRESSO, a CPU cryo-EM
submit host, and Bifrost as the model gateway in front of Vertex AI.

I built it to watch an agent do the work on real cluster objects: submit a
calculation, follow it through the scheduler, read the result. Jobs run on the
cluster. There is no simulation layer.

## What the demo does

The agent takes a request, builds a structure and a k-point grid, submits a
`pw.x` calculation through AiiDA, follows it through SLURM, reads the result,
and writes a reproducible notebook into AiiDAlab.

The components:

- **OpenClaw** — the agent gateway and its browser control UI. It holds the
    model credentials, the AiiDA MCP token, and a narrow `kubectl exec` permission
    on three named pods.
- **AiiDA + AiiDAlab** — PostgreSQL, RabbitMQ, the AiiDA daemon, JupyterLab, an
    MCP server that submits processes, and an idle pod for CLI work.
- **SLURM cluster** — one controller pod and one compute pod, both running as an
    unprivileged uid. Quantum ESPRESSO is on the compute image.
- **Cryo-EM submit host** — a CPU-only pod with RELION, CTFFIND and Pipeliner,
    working on a shared 50 GiB scratch claim.
- **Bifrost** — an OpenAI-compatible gateway that routes model calls to Vertex AI
    and issues the virtual key OpenClaw presents.

## How it is installed

The module is the only entry point. It enables k3s, builds or imports four
container images, renders the manifest tree, and applies it from a systemd unit
at activation. There is no registry in the loop and no manual `kubectl apply`
step.

Two images are built by Nix and imported into containerd. The other two are
built from Dockerfiles by the host Docker daemon at activation, because their pip
and apt dependency sets are hard to express as a Nix build. The full chain is in
[docs/architecture.md](docs/architecture.md).

## Install

1. Add the flake as an input and include `nixosModules.default`.
2. Set `nodeAddress`, `storageClass`, `vertex.project` and `secretsFile`.
3. Write the runtime dotenv with the 15 keys from `secrets.env.example`.
4. Run `nixos-rebuild switch`, wait for the image builds, check the pods.

The steps are in [docs/install.md](docs/install.md). Secret generation, the
Bifrost virtual key, the export CronJob and the Cloudflare edge are in
[docs/provisioning.md](docs/provisioning.md).

## Requirements

- NixOS with flakes enabled.
- Docker on the host (`virtualisation.docker.enable = true`). Two images are
    built with it.
- About 20 GB free for the Nix build, the Docker build and the four imported
    images. The manifests also request 206 GiB of PersistentVolumeClaims; on
    `local-path` those are thin and only consume space as they fill.
- Tens of minutes for the first activation. The AiiDAlab image installs three
    Python environments; the cryo-EM image installs RELION, CTFFIND and
    Pipeliner.
- A Google Cloud project with Vertex AI enabled and application default
    credentials for an account that may call the models. `vertex.project` is an
    assertion, so the module will not evaluate without it.
- A node address the pods can reach. The OpenClaw egress policy needs it for the
    Kubernetes API path after DNAT.

## Security defaults

No ingress by default. Every Service is `ClusterIP`, the Cloudflare tunnel is
opt-in and off, and a default install is reachable only through
`kubectl port-forward` from the host.

Every namespace enforces the restricted Pod Security Standard. Every pod runs as
a non-root uid, drops all capabilities, uses a read-only root filesystem and the
default seccomp profile.

Every namespace starts from default-deny on ingress and egress. Allowed paths are
explicit and namespace-scoped: only the edge namespace reaches the OpenClaw
control port and Jupyter; only OpenClaw reaches Bifrost and the AiiDA MCP server;
only AiiDAlab reaches the SLURM sshd and controller ports. AiiDAlab and SLURM
have no internet egress.

The agent's cluster permission is a Role with `get` and `create pods/exec` on
three named pods (`aiida-ops-0`, `slurmctld-0`, `cryoem-ops-0`). No other verbs,
no cluster-wide scope.

Secrets stay out of the Nix store. They live in a root-only dotenv named by
`secretsFile`, are read by the manifest unit at activation, and become Kubernetes
Secrets.

## Repo layout

| Path | Contents |
|---|---|
| `flake.nix` | Inputs and the exported module |
| `module.nix` | The NixOS module: options, image builds, units, manifest apply |
| `nix/render.nix` | Copies the manifests, drops held paths, renders computed pieces |
| `manifests/` | Kubernetes objects by layer, numbered for apply order |
| `images/` | Nix image expressions and the two Dockerfiles |
| `packages/` | Helper apps, including the edge ingress switch |
| `secrets.env.example` | The 15 runtime keys, empty |
| `docs/` | Architecture, install and provisioning notes |

## Docs

- [docs/architecture.md](docs/architecture.md) — components, namespaces, data
    flow, delivery chain, secrets, policy.
- [docs/install.md](docs/install.md) — install, verify, port-forward, first-run
    notes.
- [docs/provisioning.md](docs/provisioning.md) — secret values, Bifrost virtual
    key, export CronJob, Cloudflare edge.

## Scope

It is a demo. One node, one replica per service, local-path storage. The
manifests are written to make failures readable, not to survive load or keep
running unattended.
