#!/usr/bin/env bash
# Assign and apply Garage's cluster layout.
#
# A newly started Garage cluster is inert: the nodes have found each other but hold no
# data ranges, so every S3 request fails until a layout is assigned. That is CLI-only —
# there is no Kubernetes object for it — so this runs after the StatefulSet is up.
#
# Each node is placed in a zone named after the k3s node it is running on. With Garage's
# default "maximum" zone redundancy that is what actually spreads replicas across physical
# hosts rather than stacking them.
#
# Idempotent: re-running when the layout already covers every node is a no-op.
#
# Env: GARAGE_REPLICAS, GARAGE_ZONE_CAPACITY, KUBECONFIG and/or K3S_NODE_IP.
set -euo pipefail

# shellcheck source=./kube-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/kube-lib.sh"

NS=garage
REPLICAS="${GARAGE_REPLICAS:?}"
CAPACITY="${GARAGE_ZONE_CAPACITY:?}"

# The dxflrs/garage image is distroless — no shell, no coreutils. The binary is the
# entrypoint at /garage, so exec calls have to name it by absolute path.
garage_exec() {
  local pod="$1"
  shift
  kctl exec -n "$NS" "$pod" -- /garage "$@" 2>/dev/null
}

echo "waiting for ${REPLICAS} garage pods to be ready..."
for _ in $(seq 1 60); do
  ready=$(kctl get pods -n "$NS" -l app=garage \
    -o 'jsonpath={range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' \
    2>/dev/null | grep -c true || true)
  if [ "$ready" -ge "$REPLICAS" ]; then
    break
  fi
  sleep 5
done

if [ "${ready:-0}" -lt "$REPLICAS" ]; then
  echo "only ${ready:-0}/${REPLICAS} garage pods ready; giving up" >&2
  exit 1
fi

layout_before=$(garage_exec garage-0 layout show || true)

assigned=0
for i in $(seq 0 $((REPLICAS - 1))); do
  pod="garage-${i}"

  # `node id -q` prints "<id>@<host>:<port>"; the layout only wants the id.
  node_id=$(garage_exec "$pod" node id -q | tail -1 | cut -d@ -f1)
  if [ -z "$node_id" ]; then
    echo "could not read node id from ${pod}" >&2
    exit 1
  fi

  zone=$(kctl get pod -n "$NS" "$pod" -o 'jsonpath={.spec.nodeName}')
  # Zone names come from the k3s node name (k3s-tamarin-04); trim the prefix so the zone
  # reads as the physical host it actually corresponds to.
  zone="${zone#k3s-}"

  # `layout show` prints 16-character short ids while `node id` returns the full 64, so
  # the membership check has to compare the prefix or it never matches and every run
  # re-assigns.
  if grep -q "${node_id:0:16}" <<<"$layout_before"; then
    echo "${pod} (${node_id:0:16}) already in layout, zone ${zone}"
    continue
  fi

  echo "assigning ${pod} (${node_id}) to zone ${zone} with capacity ${CAPACITY}"
  garage_exec garage-0 layout assign -z "$zone" -c "$CAPACITY" "$node_id"
  assigned=$((assigned + 1))
done

if [ "$assigned" -eq 0 ]; then
  echo "layout already complete, nothing to apply"
  exit 0
fi

current_version=$(sed -n 's/.*Current cluster layout version: *\([0-9]*\).*/\1/p' \
  <<<"$layout_before" | tail -1)
: "${current_version:=0}"
next_version=$((current_version + 1))

echo "applying layout version ${next_version}"
garage_exec garage-0 layout apply --version "$next_version"

garage_exec garage-0 layout show
