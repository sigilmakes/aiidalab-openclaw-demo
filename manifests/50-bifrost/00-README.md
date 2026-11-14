# 50-bifrost — Bifrost model gateway (Vertex AI, STFC project)

Namespace `bifrost`. Upstream image `docker.io/maximhq/bifrost`, pinned by digest
(linux/amd64 manifest `sha256:d53775fd4b1d444c350443d2487ceb8aa8c0bab722cd5dc7b0001a7fa88ecd7f`,
OCI index `sha256:f5b18826349fe9e1c402c10d19f1cbb5567a3c800ad928580d07f72e69106ec7`, 2026-10-29).
See docs/provisioning.md for the GCP auth flow this depends on.

Files, applied in filename order by the `k3s-manifests` unit:

    10-configmap.yaml      bifrost-config ConfigMap: config.json + verified region/model values
    20-deployment.yaml     Deployment bifrost + Service bifrost:8080
    30-netpol.yaml         allow policies layered on top of the namespace default-deny
    40-selftest-job.yaml   Job bifrost-selftest, spec.suspend=true (manual)

## Config flow

`config.json` is read from `/app/data/config.json` (APP_DIR, the bifrost-state PVC) at every
boot and synced into config.db; `providers` sections from the file are applied on each start
(Bifrost source_of_truth=split: file keys win, DB-only entries survive, removals need a DB edit).
Model routing is per key: `claude-*` keys build `@VERTEX_REGION_CLAUDE@-aiplatform.googleapis.com`, the
`gemini-2.5-flash` key builds `@VERTEX_REGION_GEMINI@-aiplatform.googleapis.com`.

Offline boot (verified live): `pricing_url` / `model_parameters_url` point at datasheets
vendored in the ConfigMap (`file:///app/data/...`), and the MCP-library and live-models
background syncs are disabled (`0`). Without this, Bifrost v2.3.2 FATAL-exits at
"initializing model catalog" when `getbifrost.ai` is unreachable — observed first-hand during
the cluster DNS outage. Both datasheets are the small sample set; swap in the full ones
(`curl -fsSL https://getbifrost.ai/datasheet`) if usage accounting matters. Note kubelet
creates empty dirs (not errors) for subPaths missing from a filtered `items` list — the
ConfigMap volume therefore projects all keys.

`auth_credentials` is empty in both keys: Bifrost resolves
`google.FindDefaultCredentials()`, which reads `GOOGLE_APPLICATION_CREDENTIALS` —
`/etc/gcp/credentials.json`, the `vertex-credentials` Secret key `credentials.json` rendered by
the `k3s-manifests` activation unit from `VERTEX_ADC_B64` in the runtime dotenv. The file may be
an `authorized_user` ADC file or a WIF `external_account` config (workforce pool
`wif-pool-irisiam`, provider `wif-provider-irisiam-oidc`,
audience `//iam.googleapis.com/locations/global/workforcePools/wif-pool-irisiam/providers/wif-provider-irisiam-oidc`):
the Google auth library accepts both from that path.

## Verified values (parent probe, 2026-10-29, gcloud CLI token)

- `claude-sonnet-4-6` and `claude-haiku-4-5` on `:streamRawPredict`, region `@VERTEX_REGION_CLAUDE@`: HTTP 200.
- `gemini-2.5-flash`, region `@VERTEX_REGION_GEMINI@`: HTTP 200.
- Re-verify with:
  `gcloud ai model-garden models list --billing-project=@VERTEX_PROJECT@ --model-filter=claude`
- Quota-zero models (429 RESOURCE_EXHAUSTED,
  `online_prediction_input_tokens_per_minute_per_base_model`): claude-sonnet-5,
  claude-sonnet-5-5, claude-opus-4-8, claude-opus-5, claude-opus-5-5, claude-haiku-5-5.
  Quota console: https://console.cloud.google.com/apis/api/aiplatform.googleapis.com/quotas?project=@VERTEX_PROJECT@
- Not available: claude-fable-5 (403), claude-fable-5-1 (404),
  claude-opus-4-5 / claude-opus-4-6 / claude-opus-4-7 (404, @VERTEX_REGION_CLAUDE@).

## Current blocker (legible failure, not hidden)

The host `~/.config/gcloud/application_default_credentials.json` is expired
(`invalid_grant: Bad Refresh Token`); `gcloud auth login` (CLI) does NOT refresh it.
Until someone runs `gcloud auth application-default login` and the fresh ADC is re-seeded into
`VERTEX_ADC_B64` (runtime dotenv), the pod runs but every Vertex request fails with a token-refresh error
in `kubectl -n bifrost logs deploy/bifrost` and in the selftest job.

## Auth exposure (observed live, Bifrost v2.3.2)

Fresh instance, no admin account: the admin surface answers `403 Forbidden` ("The /api surface
is locked and no setup token is configured") — creating the first admin account requires a
`BIFROST_SETUP_TOKEN` env or `setup_token` in config.json. To enable auth later: set
`BIFROST_SETUP_TOKEN` from the runtime dotenv (parent wiring), create the admin account in the
dashboard, and optionally keep inference open via the "disable authentication on inference
calls" toggle. Inference is not auth-gated in the observed state; the NetworkPolicy is the
control (ingress `:8080` only from the `openclaw` namespace and same-namespace).

## Selftest (manual)

    kubectl -n bifrost apply -f services/nixos/aiidalab-openclaw-demo/manifests/50-bifrost/40-selftest-job.yaml   # if not yet applied
    kubectl -n bifrost patch job bifrost-selftest --type=merge -p '{"spec":{"suspend":false}}'
    kubectl -n bifrost logs job/bifrost-selftest           # shows model ids, HTTP status, response (model + usage)
    # re-run: kubectl -n bifrost delete job bifrost-selftest, then resume again

## Operational notes

- Live status at handover (2026-10-29): manifests applied to the running cluster; the
  Deployment is Pending (PVC) because the node's local-path-provisioner cannot reach the API —
  cluster-level, being fixed outside this directory. The placeholder credential was removed;
  when the real Secret appears at activation the pod starts without a rollout restart
  (kubelet retries failed secret mounts). Later Secret rotations DO need
  `kubectl -n bifrost rollout restart deployment/bifrost`.
- Verified live: boot from local datasheets (no network), both Vertex keys synced from
  config.json with `env.`-resolved project/region, `/health` OK (`db_pings ok`), admin surface
  403-locked without setup token, image pull by digest (100MB, 3.7s), Restricted-PSA security
  context (uid 1000, drop ALL, no privilege escalation, seccomp, RO rootfs + /tmp emptyDir).
- Unverified in-cluster: an actual Vertex completion (needs renewed ADC + working pod egress);
  DNS egress rule (coredns down); netpol traffic behavior (pod->internet timed out even from
  the policy-free `default` namespace; enforcement state was mid-rebuild for the whole cluster).
  Re-verify after the cluster generation settles: same-ns `:8080`, openclaw->bifrost, and
  internet 443 egress. My policies are spec-correct; if kube-router still drops the ipBlock
  `except` rule, pods lose all egress and that needs a decision outside this directory.
- ConfigMap or Secret content changes do not restart the pod (subPath/ConfigMap mount):
  `kubectl -n bifrost rollout restart deployment/bifrost` (or add a template hash annotation
  in the Nix-generated apply).
- PVC `bifrost-state` is owned by `manifests/20-storage.yaml` (edge worker); this directory
  only references it.
- `openclaw-to-bifrost-egress` lives in this directory but is an object in the `openclaw`
  namespace; drop it there if the openclaw/edge directory ships its own version.
