#!/usr/bin/env bash
# Publish static site content to a Garage-backed site.
#
# Content is data, so it is out of scope for Terraform by design — this is the thing you
# run after a rebuild to put the sites back.
#
# The init containers only run at pod start, so a new tarball does nothing until the
# Deployment restarts; this does both.
#
# Usage: upload-site.sh <source-dir> <bucket> <namespace> <deployment>
#   e.g. upload-site.sh ~/prg/_EXP/website_old_monkeca monke-ca placeholder monke-site
#
# Env: K3S_NODE_IP (default 192.168.2.102), GARAGE_S3_NODEPORT (default 30390),
#      KUBECONFIG and/or K3S_NODE_IP for kubectl access.
set -euo pipefail

SRC="${1:?usage: upload-site.sh <source-dir> <bucket> <namespace> <deployment>}"
BUCKET="${2:?}"
NS="${3:?}"
DEPLOY="${4:?}"

: "${K3S_NODE_IP:=192.168.2.102}"
: "${GARAGE_S3_NODEPORT:=30390}"

# shellcheck source=./kube-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/kube-lib.sh"

if [ ! -d "$SRC" ]; then
  echo "no such directory: $SRC" >&2
  exit 1
fi

SECRET_NAME="${BUCKET}-garage-key"
ACCESS_KEY=$(kctl get secret -n "$NS" "$SECRET_NAME" -o 'jsonpath={.data.access_key}' | base64 -d)
SECRET_KEY=$(kctl get secret -n "$NS" "$SECRET_NAME" -o 'jsonpath={.data.secret_key}' | base64 -d)

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
  echo "could not read ${NS}/${SECRET_NAME}" >&2
  exit 1
fi

TARBALL=$(mktemp /tmp/site-XXXXXX.tar.gz)
trap 'rm -f "$TARBALL"' EXIT

echo "packing ${SRC}..."
tar czf "$TARBALL" --exclude=.git -C "$SRC" .
echo "  $(stat -c%s "$TARBALL") bytes"

# Garage is S3-compatible but not AWS, so the endpoint has to be given explicitly and
# the region is whatever garage.toml's s3_region says.
echo "uploading to s3://${BUCKET}/site.tar.gz"
AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
AWS_DEFAULT_REGION=garage \
  aws --endpoint-url "http://${K3S_NODE_IP}:${GARAGE_S3_NODEPORT}" \
  s3 cp "$TARBALL" "s3://${BUCKET}/site.tar.gz"

echo "restarting ${NS}/${DEPLOY}"
kctl rollout restart "deployment/${DEPLOY}" -n "$NS"
kctl rollout status "deployment/${DEPLOY}" -n "$NS" --timeout=180s
