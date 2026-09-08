#!/usr/bin/env bash
# Scaffold a new app repo wired to the Tamarin cluster.
#
#   ./new-app-repo.sh <owner> <app> [domain] [target-dir]
#
# The repo it produces carries its own cluster context (CLAUDE.md + skills), its manifests,
# and the CI workflow. It does not carry credentials — those are applied from the infra
# repo into the app's namespace.
set -euo pipefail

OWNER=${1:?owner required (the person whose Postgres role and bucket this app uses)}
APP=${2:?app name required}
DOMAIN=${3:-}
DEST=${4:-$PWD/$APP}
SRC="$(cd "$(dirname "$0")" && pwd)/app-repo"

[ -e "$DEST" ] && { echo "refusing to overwrite existing $DEST" >&2; exit 1; }

mkdir -p "$DEST"
cp -r "$SRC/." "$DEST/"
find "$DEST" -type f -exec sed -i \
  -e "s|__OWNER__|$OWNER|g" -e "s|__APP__|$APP|g" \
  -e "s|__DOMAIN__|${DOMAIN:-$APP.example.invalid}|g" {} +

echo "created $DEST"
echo
echo "next:"
echo "  cd $DEST && git init && gh repo create monkecloud/$APP --private --source=."
[ -z "$DOMAIN" ] && echo "  (no domain given — delete k8s/ingress.yaml and drop it from k8s/kustomization.yaml)"
echo
echo "then, in the infra repo, add one overlay per environment and list them in"
echo "clusters/tamarin/apps/kustomization.yaml — see clusters/tamarin/apps/README.md:"
echo "  clusters/tamarin/apps/$OWNER-$APP-prod/   (branch main)"
echo "  clusters/tamarin/apps/$OWNER-$APP-dev/    (branch dev)"
