#!/bin/bash
# Check if the "Ansible Basics" scenario has been completed.
# This script runs against the running VMs to verify learning objectives.
# Exit 0 = completed, exit 1 = not completed.
#
# The lab.sh passes the following env vars:
#   SSH_PORTS="control:50221 server1:50222 server2:50223"

set -euo pipefail

check_ssh() {
  local name="$1" port="$2"
  ssh -q -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    -p "$port" root@localhost "echo ok" >/dev/null 2>&1
  return $?
}

check_ansible_installed() {
  local port="$1"
  ssh -q -o ConnectTimeout=5 -p "$port" root@localhost \
    "ansible --version >/dev/null 2>&1"
  return $?
}

# Parse SSH_PORTS into individual checks
for pair in ${SSH_PORTS//,/ }; do
  name="${pair%%:*}"
  port="${pair##*:}"
  if ! check_ssh "$name" "$port"; then
    echo "FAIL: cannot SSH to $name on port $port"
    exit 1
  fi
done

# Check Ansible is on the control node
control_port=$(echo "$SSH_PORTS" | tr ',' '\n' | grep control | cut -d: -f2)
if ! check_ansible_installed "$control_port"; then
  echo "FAIL: Ansible not installed on control node"
  exit 1
fi

echo "All checks passed."
exit 0
