#!/usr/bin/env bash
# Ensure a Garage bucket and a bucket-scoped access key exist, then publish the key as a
# Kubernetes Secret for the site Deployment to mount.
#
# Buckets and keys are Garage CLI concepts with no Kubernetes representation, so this runs
# as a provisioner. Writing the credentials directly into a Secret keeps them out of
# Terraform state entirely.
#
# Keys are scoped to a single bucket on purpose: a site's credentials should not be able
# to read or delete any other site's content.
#
# Idempotent: safe to re-run, and re-runs recover the existing key rather than rotating it.
#
# Env: GARAGE_BUCKET, GARAGE_KEY_NAME, TARGET_NAMESPACE, TARGET_SECRET_NAME,
#      KUBECONFIG and/or K3S_NODE_IP.
set -euo pipefail

# shellcheck source=./kube-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/kube-lib.sh"

NS=garage
POD=garage-0

BUCKET="${GARAGE_BUCKET:?}"
KEY_NAME="${GARAGE_KEY_NAME:?}"
TARGET_NS="${TARGET_NAMESPACE:?}"
SECRET_NAME="${TARGET_SECRET_NAME:?}"

# Distroless image: the binary is the entrypoint at /garage and there is no shell.
garage() {
  kctl exec -n "$NS" "$POD" -- /garage "$@" 2>/dev/null
}

echo "waiting for garage to be ready..."
for _ in $(seq 1 60); do
  if garage status >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

if ! garage bucket info "$BUCKET" >/dev/null 2>&1; then
  echo "creating bucket ${BUCKET}"
  garage bucket create "$BUCKET"
else
  echo "bucket ${BUCKET} already exists"
fi

if ! garage key info "$KEY_NAME" >/dev/null 2>&1; then
  echo "creating key ${KEY_NAME}"
  garage key create "$KEY_NAME" >/dev/null
fi

key_info=$(garage key info "$KEY_NAME" --show-secret)
ACCESS_KEY=$(sed -n 's/^Key ID: *//p' <<<"$key_info" | tr -d '[:space:]')
SECRET_KEY=$(sed -n 's/^Secret key: *//p' <<<"$key_info" | tr -d '[:space:]')

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
  echo "could not read credentials for key ${KEY_NAME}" >&2
  exit 1
fi

echo "granting ${KEY_NAME} read/write on ${BUCKET}"
garage bucket allow --read --write "$BUCKET" --key "$KEY_NAME" >/dev/null

# Recreate rather than patch: `kubectl apply -f -` would need stdin, which does not
# survive the SSH fallback path in kube-lib.sh.
echo "writing secret ${TARGET_NS}/${SECRET_NAME}"
kctl delete secret -n "$TARGET_NS" "$SECRET_NAME" --ignore-not-found >/dev/null
kctl create secret generic "$SECRET_NAME" \
  -n "$TARGET_NS" \
  --from-literal=access_key="$ACCESS_KEY" \
  --from-literal=secret_key="$SECRET_KEY" >/dev/null

echo "done: bucket ${BUCKET}, key ${ACCESS_KEY}"
