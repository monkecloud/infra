# Shared kubectl wrapper, sourced by the bootstrap scripts.
#
# A few things here genuinely can't be expressed as Terraform resources — Garage's layout
# assignment and its bucket/key admin are CLI-only operations against a running pod — so
# they run through this instead.
#
# dt2 does not necessarily have kubectl installed, so this prefers a local binary and
# falls back to running kubectl on a cluster node over SSH.
#
# Usage:  source kube-lib.sh; kctl get pods -n garage
# Env:    KUBECONFIG    path to the admin kubeconfig (local mode)
#         K3S_NODE_IP   a k3s server node to fall back to (ssh mode)

# shellcheck source=./ssh-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh-lib.sh"

_KCTL_MODE=""

_kctl_detect() {
  [ -n "$_KCTL_MODE" ] && return 0

  if command -v kubectl >/dev/null 2>&1 && [ -n "${KUBECONFIG:-}" ] && [ -r "${KUBECONFIG:-}" ]; then
    if kubectl version --request-timeout=10s >/dev/null 2>&1; then
      _KCTL_MODE="local"
      return 0
    fi
  fi

  if [ -n "${K3S_NODE_IP:-}" ]; then
    _KCTL_MODE="ssh"
    return 0
  fi

  echo "no usable kubectl: install kubectl and set KUBECONFIG, or set K3S_NODE_IP" >&2
  return 1
}

kctl() {
  _kctl_detect || return 1

  if [ "$_KCTL_MODE" = "local" ]; then
    kubectl "$@"
  else
    # Quote each argument so it survives the remote shell intact.
    local quoted=""
    local a
    for a in "$@"; do
      quoted="$quoted $(printf '%q' "$a")"
    done
    node_ssh "$K3S_NODE_IP" "kubectl$quoted"
  fi
}
