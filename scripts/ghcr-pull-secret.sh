#!/usr/bin/env bash
# Write a GHCR pull secret for one app namespace, SOPS-encrypted.
#
#   ./scripts/ghcr-pull-secret.sh <namespace> [github-username]
#
# Needs a PAT with only `read:packages`:
#   https://github.com/settings/tokens/new?scopes=read:packages&description=ghcr%20pull%20tamarin
# The token is prompted for, never passed as an argument, and only ciphertext is written.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=${1:?usage: ghcr-pull-secret.sh <namespace> [github-username]}
USER=${2:-$(gh api /user --jq .login 2>/dev/null || true)}
[ -n "$USER" ] || { echo "could not determine your GitHub username; pass it as arg 2" >&2; exit 1; }
DIR="clusters/tamarin/apps/$NS"
[ -d "$DIR" ] || { echo "no such app overlay: $DIR" >&2; exit 1; }
OUT="$DIR/ghcr-creds.sops.yaml"

TOKEN=${GHCR_TOKEN:-}
if [ -z "$TOKEN" ]; then
  [ -t 0 ] || { echo "error: no TTY; set GHCR_TOKEN in the environment instead" >&2; exit 1; }
  read -rsp "GitHub PAT with read:packages: " TOKEN; echo
fi
[ -n "$TOKEN" ] || { echo "error: empty token" >&2; exit 1; }

AUTH=$(printf '%s:%s' "$USER" "$TOKEN" | base64 -w0)
DOCKERCFG=$(printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$AUTH" | base64 -w0)

TMP="${OUT}.plain.sops.yaml"
trap 'shred -u "$TMP" 2>/dev/null || rm -f "$TMP"' EXIT
cat > "$TMP" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-creds
  namespace: $NS
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $DOCKERCFG
YAML
sops --encrypt --config .sops.yaml --input-type yaml --output-type yaml "$TMP" > "$OUT"
echo "wrote $OUT"
