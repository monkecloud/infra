#!/usr/bin/env bash
# Fetch the admin kubeconfig from the k3s cluster-init node and point it at that node's
# real IP (k3s writes 127.0.0.1, which is only useful on the node itself).
#
# Usage: fetch-kubeconfig.sh <server-ip> <output-path>
set -euo pipefail

SERVER_IP="${1:?usage: fetch-kubeconfig.sh <server-ip> <output-path>}"
OUT="${2:?usage: fetch-kubeconfig.sh <server-ip> <output-path>}"

# shellcheck source=./ssh-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh-lib.sh"

echo "waiting for ssh on ${SERVER_IP}..."
node_wait_ssh "$SERVER_IP"

# cloud-init enables k3s in runcmd, so the file can lag the first successful ssh.
echo "waiting for k3s admin kubeconfig..."
for _ in $(seq 1 60); do
  if node_ssh "$SERVER_IP" "test -s /etc/rancher/k3s/k3s.yaml"; then
    break
  fi
  sleep 10
done

mkdir -p "$(dirname "$OUT")"
node_ssh "$SERVER_IP" "cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s#https://127\.0\.0\.1:6443#https://${SERVER_IP}:6443#" >"$OUT"

chmod 600 "$OUT"

if ! grep -q "server: https://${SERVER_IP}:6443" "$OUT"; then
  echo "kubeconfig does not point at ${SERVER_IP} — refusing to leave it in place" >&2
  rm -f "$OUT"
  exit 1
fi

echo "wrote ${OUT}"
