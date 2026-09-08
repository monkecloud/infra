# Shared SSH helper, sourced by the other scripts in this tree.
#
# dt2 has no sshpass/expect/paramiko, so non-interactive password auth goes through
# SSH_ASKPASS. If key auth works, that path is skipped entirely — which is why
# ssh_public_key is worth setting in 10-vms.
#
# Usage:  source ssh-lib.sh; node_ssh <host> <command...>
# Env:    NODE_ROOT_PASSWORD (optional, defaults to the pool convention)

# No default: the real password must not live in this repo. Export NODE_ROOT_PASSWORD
# before running anything that SSHes to a node.
if [ -z "${NODE_ROOT_PASSWORD:-}" ]; then
  echo "NODE_ROOT_PASSWORD is not set (root password for the k3s node VMs)" >&2
  exit 1
fi

_ASKPASS_FILE=""

_ensure_askpass() {
  [ -n "$_ASKPASS_FILE" ] && return 0
  _ASKPASS_FILE="$(mktemp)"
  printf '#!/bin/sh\nprintf %%s "%s"\n' "$NODE_ROOT_PASSWORD" >"$_ASKPASS_FILE"
  chmod 700 "$_ASKPASS_FILE"
  # shellcheck disable=SC2064
  trap "rm -f '$_ASKPASS_FILE'" EXIT
}

node_ssh() {
  local host="$1"
  shift

  # -n matters: without it ssh reads the caller's stdin, so calling this inside a loop
  # that is itself reading stdin silently eats the rest of the script. Nothing here needs
  # to pipe input to a remote command.
  local opts=(
    -n
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
  )

  # Try key auth first; fall back to the askpass dance only if it fails.
  if ssh "${opts[@]}" -o BatchMode=yes "root@$host" true 2>/dev/null; then
    ssh "${opts[@]}" -o BatchMode=yes "root@$host" "$@"
    return $?
  fi

  _ensure_askpass
  SSH_ASKPASS="$_ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force \
    setsid ssh "${opts[@]}" "root@$host" "$@"
}

node_wait_ssh() {
  local host="$1" tries="${2:-60}" i=0
  while [ "$i" -lt "$tries" ]; do
    if node_ssh "$host" true >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 10
  done
  echo "timed out waiting for ssh on $host" >&2
  return 1
}
