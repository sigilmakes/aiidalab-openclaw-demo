# Architecture

The module owns a single-node k3s cluster on the host and installs the whole
demo into it.

## Component map

### Namespaces

| Namespace | Purpose |
|---|---|
| `openclaw` | Agent gateway, control UI, portal relay |
| `aiidalab` | PostgreSQL, RabbitMQ, JupyterLab, AiiDA daemon, MCP server, ops pod |
| `slurm` | SLURM controller, one compute node, cryo-EM submit host |
| `bifrost` | Model gateway in front of Vertex AI |
| `edge` | Optional Cloudflare tunnel connector |

All five carry `pod-security.kubernetes.io/enforce=restricted` plus the audit and
warn labels. Every namespace starts from a default-deny ingress and egress
policy; the allow rules are explicit.

### `openclaw`

| Object | Notes |
|---|---|
| Deployment `openclaw` | Two containers: `gateway` (port 18789) and `portal-bridge` (18791, relays the gateway's loopback portal listener). Two init containers seed the Nix store and create the state directories |
| Service `openclaw` | ClusterIP. `18789` to the gateway; `18790` to the portal-bridge on pod port 18791 |
| ConfigMap `openclaw-config` | `openclaw.json`: model catalogue, MCP server, gateway auth, browser SSRF allowlist |
| ConfigMaps `openclaw-skills`, `openclaw-cluster-skills` | Skill documents projected at `/etc/openclaw/skills` |
| ServiceAccount + Roles `openclaw-ops` | `get` pod and `create pods/exec` on three named pods only |
| Secrets `openclaw-gateway`, `bifrost-vk`, `aiida-mcp-client` | Control UI password, Bifrost virtual key, MCP bearer token |
| PVCs `openclaw-state` (20 Gi), `openclaw-nix` (64 Gi) | `/srv/openclaw` and `/nix` |

The gateway image carries its own Nix store. Because the `openclaw-nix` claim
mounts over `/nix`, an init container seeds the claim from the image store and
the gateway container loads the store registration at start. The agent therefore
has a writable Nix store for throwaway tooling.

### `aiidalab`

| Object | Notes |
|---|---|
| StatefulSet `aiidalab-postgres` | PostgreSQL 17.6, uid 999, PVC 20 Gi, user `aiida`, database `aiidadb` |
| StatefulSet `aiidalab-rabbitmq` | RabbitMQ 4.1.4, uid 999, PVC 5 Gi |
| Deployment `aiidalab-jupyter` | JupyterLab with the AiiDA profile, port 8888, PVC `aiidalab-home` 30 Gi |
| Deployment `aiida-daemon` | `verdi daemon start --foreground 1`; mounts the SLURM key at `/etc/slurm-key` and nowhere else |
| StatefulSet `aiida-ops` | Idle pod `aiida-ops-0` for read-only CLI work over `kubectl exec` |
| Deployment `aiida-mcp` | `front.py` (bearer token, port 8080) in front of `mcp-proxy` (8081) in front of `server.py` |
| ConfigMaps `aiida-mcp-code`, `aiida-tools`, `aiida-slurm-override` | MCP server and tool sources, retrieved-file exporter, scheduler override |
| Job `aiidalab-bootstrap-<hash>` | Idempotent profile, computer, code and pseudopotential setup |
| CronJob `files-export` | Held by default; exports retrieved files to `notebooks/<pk>-files/` |

The bootstrap job creates the AiiDA profile `aiidalab`, the computer
`slurm-local` (SSH + SLURM to the `slurm` namespace), one code per installed
Quantum ESPRESSO executable, and the SSSP 1.3 PBE/efficiency family from an
archive baked into the image. It needs no network.

`aiida-slurm-override` ships a `sitecustomize.py` that forces
`import_sys_environment = False` on every submit script. A rootless `slurmd`
cannot honour `--get-user-env`, and AiiDA emits it by default.

### `slurm`

| Object | Notes |
|---|---|
| StatefulSet `slurmctld` | `munged` (uid 998), `slurmctld` (uid 1000), `sshd` (uid 1000, in-pod port 2222) |
| Deployment `slurmd` | Hostname fixed to `compute01`; `munged`, `slurmd` (uid 1000), `node-reconciler` |
| StatefulSet `cryoem-ops` | CPU cryo-EM submit host, uid 1000, PVC `cryoem-scratch` 50 Gi |
| Services `slurm`, `slurmctld`, `slurmd` | `slurm` maps 22 to 2222 and exposes 6817; the other two are headless and publish not-ready addresses |
| Job `slurm-selftest` | Proves munge, node registration, dispatch, completion and `pw.x` presence |
| PVCs `slurm-state` (2 Gi), `slurm-scratch` (10 Gi) | Controller state and shared job scratch |

`slurm.conf` defines cluster `sandbox`, node `compute01` (8 CPUs, 15000 MB) and
partitions `debug` and `batch`. `SlurmUser` and `SlurmdUser` are both `aiida`,
so no process in the namespace needs root, a setuid binary or a privileged
port. `proctrack/linuxproc` replaces `proctrack/pgid`, and `CgroupPlugin` is
disabled, both because the rootless daemons cannot use the default mechanisms.

Two sidecars keep the daemons alive across restarts. `munged-supervisor.sh`
restarts `munged` when the mounted munge key changes, in both pods. The
`node-reconciler` points the controller at the compute pod's current address and
resumes a node that is not usable.

### `bifrost`

| Object | Notes |
|---|---|
| Deployment `bifrost` | Digest-pinned upstream image, uid 1000, port 8080, PVC `bifrost-state` 5 Gi |
| ConfigMap `bifrost-config` | `config.json`, region and model constants, local pricing datasheets |
| Service `bifrost` | ClusterIP, port 8080 |
| Secrets `vertex-credentials`, `bifrost-setup` | Vertex ADC JSON at `/etc/gcp/credentials.json`, setup token |
| Job `bifrost-selftest` | Created suspended; run it by hand |

Bifrost reads `config.json` at every boot and resolves
`google.FindDefaultCredentials()`, so the ADC file is the only credential it
needs. Pricing and model-parameter data come from files in the same ConfigMap,
so the gateway boots without internet access.

### `edge`

Opt-in, and empty when disabled: with `ingress.enable = false` the module drops
the whole `70-edge` directory before applying anything. When enabled it applies
a two-replica `cloudflared` Deployment and a ConfigMap whose only ingress rule
is a catch-all 502. Serving real hostnames is a separate, explicit step; see
[provisioning.md](provisioning.md).

## Data flow

```mermaid
flowchart LR
    browser[Browser] --> edge[cloudflared]
    edge -->|18789| gw[openclaw]
    gw -->|8080| bf[bifrost] -->|443| vertex[Vertex AI]
    gw -->|8080| mcp[aiida-mcp] --> daemon[AiiDA daemon]
    daemon -->|8888| lab[AiiDAlab]
    daemon -->|22| slurm[slurmctld] -->|pw.x| qe[compute01]
```

A browser reaches `openclaw:18789` through a port-forward, or through the edge
when `ingress.enable` is set. The gateway password is in `openclaw-gateway`.

OpenClaw calls Bifrost with the virtual key from `bifrost-vk`. For AiiDA it calls
`aiida-mcp:8080` with the token from `aiida-mcp-client`; `front.py` checks it,
`mcp-proxy` forwards to the stdio server, and the server submits the job.

The daemon SSHes to `slurm:22`, which lands on the controller sshd at 2222.
`sbatch` reaches `slurmctld` on 6817, which dispatches to `slurmd` on 6818;
`pw.x` runs as uid 1000 in `/scratch/aiida`. The daemon retrieves the files, and
the MCP server writes the notebook through the Jupyter API on 8888.

`kubectl exec` into `aiida-ops-0`, `slurmctld-0` or `cryoem-ops-0` goes through
the Kubernetes API on the node address. Cryo-EM tools run in the foreground in
`cryoem-ops-0` and skip AiiDA.

## Delivery chain

An activation runs four units in order.

```mermaid
sequenceDiagram
    participant Nix as flake
    participant IMG as k3s-images
    participant Docker as Docker
    participant M as k3s-manifests
    participant API as k3s

    Nix->>IMG: openclaw, slurm archives
    IMG->>API: import images
    Docker->>API: build and import aiidalab, cryoem
    M->>API: wait for /readyz
    M->>API: create Secrets from dotenv
    M->>API: apply namespaces and layers
    M->>API: restart cloudflared (edge only)
```

1. `k3s-images` imports the two Nix archives with `k3s ctr images import` and
    fails if `sandbox.local/openclaw:2026.10.7` or `sandbox.local/slurm:26.05.5`
    is missing. A changed derivation reimports.

2. `k3s-cryoem-image` and `k3s-aiidalab-image` build with host Docker, import
    into containerd, and stamp a hash in `/var/lib`; a matching stamp skips the
    build. Both have a 60-minute timeout.

3. `nix/render.nix` copies `manifests/`, drops held paths, writes the bootstrap
    ConfigMap, substitutes every `@TOKEN@`, and fails if a placeholder survives.

4. `k3s-manifests` waits up to 60 seconds for `/readyz`, creates the Secrets from
    the dotenv, decodes key material into `/run`, applies the layers, and rolls
    `cloudflared` when the edge is enabled. Restart triggers are the rendered tree
    and `secretsFile`.

Apply order is `00-namespaces`, then `10-network-policy`, `20-storage`,
`35-slurm`, `40-aiidalab`, `50-bifrost`, `60-openclaw`, and `70-edge` when the
edge is enabled.

Held by default: `40-aiidalab/82-export-cron.yaml` unless
`releaseExportCron = true`, and `70-edge` unless `ingress.enable = true`.

## Secrets flow

The dotenv is the single source of truth. It is named by `secretsFile`
(default `/run/secrets/aiidalab-openclaw-demo.env`), lives outside the Nix
store, and is read only by the root manifest unit.

```
dotenv on disk
    |  read line by line into shell variables by k3s-manifests
    v
kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -
    v
Kubernetes Secrets in four namespaces, five with the edge
    |  env valueFrom.secretKeyRef, or a file mounted from the Secret
    v
pod environment or mounted file
```

Key material gets one extra step: `AIIDA_SLURM_KEY_B64`, `MUNGE_KEY_B64` and
`VERTEX_ADC_B64` are base64-decoded into a `mktemp` directory under `/run`, with
mode 0600, and the unit removes that directory on exit.

| Secret | Namespace | Consumers |
|---|---|---|
| `openclaw-gateway` | `openclaw` | gateway password env |
| `bifrost-vk` | `openclaw` | `BIFROST_VK` env |
| `aiida-mcp-client` | `openclaw` | MCP bearer token env |
| `aiidalab-db` | `aiidalab` | postgres, bootstrap job |
| `aiidalab-rabbitmq` | `aiidalab` | rabbitmq, bootstrap job |
| `aiidalab-jupyter` | `aiidalab` | Jupyter token file, MCP server |
| `aiida-mcp` | `aiidalab` | MCP server token |
| `aiidalab-slurm` | `aiidalab` | daemon, ops pod, bootstrap job (`/etc/slurm-key`) |
| `munge-key` | `slurm` | controller and compute pods |
| `slurm-ssh` | `slurm` | controller sshd `authorized_keys` |
| `vertex-credentials` | `bifrost` | `/etc/gcp/credentials.json` |
| `bifrost-setup` | `bifrost` | `BIFROST_SETUP_TOKEN` env |
| `cloudflared-credentials` | `edge` | connector credential file |

`BIFROST_VK` and `AIIDA_MCP_TOKEN` may be empty. An empty `BIFROST_VK` keeps an
existing Secret and does nothing on a fresh install; an empty `AIIDA_MCP_TOKEN`
reuses the live Secret or generates a random token. The unit warns on the first
case because OpenClaw then has no model credential.

The SLURM key is mounted only where it is needed. The bootstrap job stages it in
`$HOME/.ssh`, then removes it and reconfigures the transport to use
`/etc/slurm-key/id_ed25519`, so the shared home claim does not hold a SLURM
credential that the Jupyter and MCP pods can read.

## Network policy

`manifests/10-network-policy.yaml` installs default-deny ingress and egress in
every namespace. Each workload directory adds explicit allows. Allow policies are
additive: a second one for the same pods only widens the first.

```mermaid
flowchart TB
    subgraph host[host: single k3s node]
        fw[firewall: cni0, flannel.1 trusted]
        edge[edge: cloudflared]
        oc[openclaw]
        ai[aiidalab]
        sl[slurm]
        bf[bifrost]
        api[kube API]

        edge -->|18789, 18791| oc
        edge -->|8888| ai
        oc -->|8080| bf
        oc -->|8080| ai
        oc -->|6443| api
        ai -->|22, 6817| sl
    end

    lan[LAN subnet] -.->|"8472, 10250, 6443"| fw
```

All five namespaces are default-deny; the arrows are the explicit allows.
`cryoem-ops` is reached only through `kubectl exec`, and everything may reach
`kube-dns` on 53.

Ports in the policies are pod ports, because kube-router evaluates egress after
DNAT. A Service port of 22 for SLURM is 2222 on the wire; a Service port of
18790 for portals is 18791 on the pod.

| From | To | Ports |
|---|---|---|
| `edge` | `openclaw` | 18789, 18791 |
| `edge` | `aiidalab` (Jupyter) | 8888 |
| `openclaw` | `bifrost` | 8080 |
| `openclaw` | `aiidalab` (`aiida-mcp`) | 8080 |
| `openclaw` | Kubernetes API | node address, 6443, and 10.43.0.1:443 |
| `openclaw` | public internet | any port, private and link-local ranges excluded |
| `aiidalab` | `slurm` | 22, 2222, 6817 |
| `aiidalab` | itself | 5432, 5672, 8080, 8888 |
| `bifrost` | public internet | 443, private ranges excluded |
| `slurm` | itself | any |
| everything | kube-dns | 53 |

`aiidalab` and `slurm` have no internet egress. That is why the bootstrap script
installs pseudopotentials from a baked archive and why the cryo-EM image ships
its tools inside the image.

The `nodeAddress` option exists for one rule: the Kubernetes API Service address
10.43.0.1 rewrites to the node address before the egress policy is evaluated, so
allowing the Service address alone would not permit `kubectl exec`.

## Host level

The module enables k3s with `--secrets-encryption`, a 0600 kubeconfig and a
kubelet bound to 127.0.0.1, and disables the bundled Traefik and ServiceLB. There
is no ingress controller, so nothing is published by default.

`hardenHostFirewall` (default true) trusts `cni0` and `flannel.1` and, when
`lanSubnet` is set, drops VXLAN (8472), kubelet (10250) and the API (6443) from
that subnet. It only takes effect when the host runs the NixOS iptables
firewall.
