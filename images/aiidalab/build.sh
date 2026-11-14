#!/usr/bin/env bash
# Build the AiiDAlab stack image and import it into the local k3s containerd
# store. No registry is involved: the manifests reference the same RepoTag the
# build produces, and imagePullPolicy IfNotPresent keeps kubelet from looking
# one up.
#
# The NixOS module does this at activation (k3s-aiidalab-image.service). Run it
# by hand only when iterating on the image without a rebuild.
set -euo pipefail
cd "$(dirname "$0")"

TAG="${AIIDALAB_TAG:-26.10.0}"
REF="sandbox.local/aiidalab:${TAG}"

docker build -t "$REF" .
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
docker save "$REF" -o "$tmp"
sudo k3s ctr images import "$tmp"
echo "imported $REF"
