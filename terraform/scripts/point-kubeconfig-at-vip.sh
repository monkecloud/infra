#!/usr/bin/env bash
# Point an existing kubeconfig at the control-plane VIP, once that VIP actually answers.
#
# Usage: point-kubeconfig-at-vip.sh <api-vip> <kubeconfig-path>
#
# Safe to re-run: if the file already names the VIP this is a no-op.
set -euo pipefail

VIP="${1:?usage: point-kubeconfig-at-vip.sh <api-vip> <kubeconfig-path>}"
KUBECONFIG_PATH="${2:?usage: point-kubeconfig-at-vip.sh <api-vip> <kubeconfig-path>}"

if [[ ! -s "$KUBECONFIG_PATH" ]]; then
  echo "kubeconfig not found at ${KUBECONFIG_PATH}" >&2
  exit 1
fi

if grep -q "server: https://${VIP}:6443" "$KUBECONFIG_PATH"; then
  echo "kubeconfig already points at ${VIP}"
  exit 0
fi

# kube-vip elects a leader and gratuitously ARPs; give it a moment after rollout.
echo "waiting for the API to answer on ${VIP}..."
ok=0
for _ in $(seq 1 24); do
  # -k on purpose: this only proves something is listening and speaking TLS. Certificate
  # verification is checked properly below, with the real CA from the kubeconfig.
  if curl -sk --max-time 4 "https://${VIP}:6443/readyz" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 5
done

if [[ "$ok" -ne 1 ]]; then
  echo "nothing answered on https://${VIP}:6443 after ~2 minutes." >&2
  echo "leaving ${KUBECONFIG_PATH} untouched. Check: kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-vip-ds" >&2
  exit 1
fi

cp "$KUBECONFIG_PATH" "${KUBECONFIG_PATH}.pre-vip"
sed -i -E "s#server: https://[0-9.]+:6443#server: https://${VIP}:6443#" "$KUBECONFIG_PATH"

if ! grep -q "server: https://${VIP}:6443" "$KUBECONFIG_PATH"; then
  echo "rewrite failed; restoring" >&2
  mv "${KUBECONFIG_PATH}.pre-vip" "$KUBECONFIG_PATH"
  exit 1
fi

# Now verify for real, with certificate verification on. This is what catches a missing
# tls-san: the API answers, but the cert does not carry the VIP.
if command -v kubectl >/dev/null 2>&1; then
  if ! KUBECONFIG="$KUBECONFIG_PATH" kubectl get --raw /readyz >/dev/null 2>&1; then
    echo "kubectl failed against ${VIP} with certificate verification on." >&2
    echo "Most likely the apiserver cert has no SAN for ${VIP} — check tls-san in" >&2
    echo "/etc/rancher/k3s/config.yaml on every node (layer 10 sets this at first boot)." >&2
    mv "${KUBECONFIG_PATH}.pre-vip" "$KUBECONFIG_PATH"
    exit 1
  fi
fi

rm -f "${KUBECONFIG_PATH}.pre-vip"
echo "kubeconfig now points at https://${VIP}:6443"
