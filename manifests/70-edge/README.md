# Cloudflare edge (optional)

This directory declares the `cloudflared` connector and the demo ingress
switch. Nothing here is active unless the module's `ingress.enable` option is
set; the default install exposes no hostnames.

## Files

- `cloudflared.yaml` — the connector Deployment plus the *closed* config map.
  Its only ingress rule is a catch-all 502, so a running connector serves
  nothing.
- `cloudflared-demo.yaml` — the *open* config map with the three routes. The
  module does not apply it; copy its `config.yml` into the live
  `cloudflared-ingress` ConfigMap for a demo window, then revert. That switch
  is what keeps the demo from being permanently exposed.

The connector mounts its tunnel credential from the `cloudflared-credentials`
Secret. The module builds that Secret from `ingress.credentialsFile` when it is
set, otherwise from the three `CLAW_TUNNEL_*` dotenv keys. Two replicas run for
availability; both read the same tunnel.

## Routes

| Public hostname | Backend |
|---|---|
| `ingress.clawHostname` | `openclaw:18789` (Control UI) |
| `ingress.aiidaHostname` | `aiidalab:8888` (Jupyter/AiiDAlab) |
| `*.<ingress.portalDomain>` | `openclaw:18790` (per-session portals) |

All three are expected to sit behind Cloudflare Access. The module accepts the
team name and one Access application audience tag per route and writes them
into the open config; when a tag is empty that route is left without an
`access` block, so protect it another way before opening it.

## Portal wildcard constraint

Portals are `<id>.<portal-domain>`. The portal domain must have a certificate
covering the apex and exactly one wildcard level:

    <portal-domain>, *.<portal-domain>

A two-label name such as `*.portal.<zone>` is not covered by a standard
Universal SSL certificate and the edge aborts the TLS handshake. Use an
advanced or custom certificate if you need a deeper name.

## Account state the manifests cannot create

- a proxied wildcard CNAME from the portal domain to `<tunnel-id>.cfargotunnel.com`;
- one Access application per hostname pattern (the wildcard app included);
- an identity provider and policy for those applications;
- DNS records for the two explicit hostnames.

None of these are rendered here, and none of their identifiers belong in the
repository.

## Verification

    curl -sSI https://<claw-host>/
    curl -sSI https://<aiida-host>/
    # both 302 to the Access login when Access is configured

    curl -sSI https://<id>.<portal-domain>/
    # 302 to the Access login for the wildcard application

If the closed config is live, every hostname returns a 502 instead.
