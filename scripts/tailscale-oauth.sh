#!/usr/bin/env bash
# Write the Tailscale OAuth client into the repo, SOPS-encrypted.
#
# The credential never passes through a shell argument (it would land in history) or through
# a chat window: this prompts for it, encrypts it, and writes only ciphertext to disk.
#
# Before running, in the Tailscale admin console:
#   1. Access controls: define the tags and let the OAuth client own them, e.g.
#        "tagOwners": { "tag:k8s-operator": ["autogroup:admin"],
#                       "tag:k8s-router":   ["tag:k8s-operator"] }
#   2. Auto-approve the routes, so a rebuilt or rescheduled router needs no clicking:
#        "autoApprovers": { "routes": { "192.168.2.0/24": ["tag:k8s-router"],
#                                       "10.43.0.0/16":   ["tag:k8s-router"] } }
#   3. Settings -> OAuth clients -> Generate: scopes `auth_keys` (write) and `devices:core`
#      (write), tag tag:k8s-operator. Copy the client ID and secret.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=clusters/tamarin/platform/tailscale--operator-oauth.sops.yaml

[ -e "$OUT" ] && { echo "refusing to overwrite existing $OUT" >&2; exit 1; }

read -rp  "Tailscale OAuth client ID: " CLIENT_ID
read -rsp "Tailscale OAuth client secret: " CLIENT_SECRET; echo

# The temp file must itself match the .sops.yaml path_regex (*.sops.yaml) or sops finds no
# creation rule and refuses to encrypt, so it is named accordingly and shredded on exit.
TMP="${OUT}.plain.sops.yaml"
trap 'shred -u "$TMP" 2>/dev/null || rm -f "$TMP"' EXIT
cat > "$TMP" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: operator-oauth
  namespace: tailscale
type: Opaque
stringData:
  client_id: "$CLIENT_ID"
  client_secret: "$CLIENT_SECRET"
YAML

sops --encrypt --config .sops.yaml --input-type yaml --output-type yaml "$TMP" > "$OUT"
echo "wrote $OUT"
echo
echo "next: uncomment the tailscale entries in"
echo "  clusters/tamarin/platform/kustomization.yaml"
echo "  clusters/tamarin/platform-config/kustomization.yaml"
echo "then commit and push; Flux does the rest."
