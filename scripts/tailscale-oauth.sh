#!/usr/bin/env bash
# Write the Tailscale OAuth client into the repo, SOPS-encrypted.
#
# The credential is never passed as a command-line argument (it would land in shell history)
# and never has to be pasted into a chat window. Three ways to supply it:
#
#   interactive        ./scripts/tailscale-oauth.sh              (prompts; needs a real TTY)
#   from a file        ./scripts/tailscale-oauth.sh --secret-file /path/to/secret.txt
#   from the env       TS_OAUTH_CLIENT_ID=... TS_OAUTH_CLIENT_SECRET=... ./scripts/...
#
# Before running, in the Tailscale admin console:
#   1. Access controls: define the tags and let the OAuth client own them, e.g.
#        "tagOwners": { "tag:k8s-operator": ["autogroup:admin"],
#                       "tag:k8s-router":   ["tag:k8s-operator"] }
#   2. Auto-approve the routes, so a rebuilt or rescheduled router needs no clicking:
#        "autoApprovers": { "routes": { "192.168.2.0/24": ["tag:k8s-router"],
#                                       "10.43.0.0/16":   ["tag:k8s-router"] } }
#   3. Settings -> OAuth clients -> Generate: scopes `auth_keys` (write) and `devices:core`
#      (write), tagged tag:k8s-operator. Copy the client ID and the secret.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=clusters/tamarin/platform/tailscale--operator-oauth.sops.yaml

SECRET_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --secret-file) SECRET_FILE=${2:?--secret-file needs a path}; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

CLIENT_ID=${TS_OAUTH_CLIENT_ID:-}
CLIENT_SECRET=${TS_OAUTH_CLIENT_SECRET:-}

if [ -n "$SECRET_FILE" ]; then
  # A file holding either "<secret>" or "<client-id>\n<secret>".
  mapfile -t LINES < "$SECRET_FILE"
  if [ "${#LINES[@]}" -ge 2 ] && [ -z "$CLIENT_ID" ]; then
    CLIENT_ID=${LINES[0]}
    CLIENT_SECRET=${LINES[1]}
  else
    CLIENT_SECRET=${LINES[0]}
  fi
fi

if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
  if [ ! -t 0 ]; then
    echo "error: no TTY, and the credential was not supplied." >&2
    echo "       run this in a normal terminal, or use --secret-file / the env vars." >&2
    echo "       (see --help)" >&2
    exit 1
  fi
  [ -z "$CLIENT_ID" ]     && read -rp  "Tailscale OAuth client ID: " CLIENT_ID
  [ -z "$CLIENT_SECRET" ] && { read -rsp "Tailscale OAuth client secret: " CLIENT_SECRET; echo; }
fi

# Refuse to write half a credential — an empty value here produces an operator that cannot
# authenticate, with nothing in the file to show why.
[ -n "$CLIENT_ID" ]     || { echo "error: client ID is empty" >&2; exit 1; }
[ -n "$CLIENT_SECRET" ] || { echo "error: client secret is empty" >&2; exit 1; }
case "$CLIENT_SECRET" in
  tskey-client-*) ;;
  *) echo "error: the secret does not look like an OAuth client secret (expected tskey-client-...)." >&2
     echo "       set TS_ALLOW_ODD_SECRET=1 to write it anyway." >&2
     [ "${TS_ALLOW_ODD_SECRET:-}" = 1 ] || exit 1 ;;
esac

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
