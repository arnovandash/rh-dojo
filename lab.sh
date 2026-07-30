#!/usr/bin/env bash
# rh-dojo — Red Hat learning lab for Apple Silicon.
#
# Scenario-based: each scenario declares only the VMs it needs. Quick configs
# let you spin up ad-hoc topologies. Completion is tracked and persists across
# sessions so you can see what you've finished.
#
#   ./lab.sh          interactive TUI menu
#   ./lab.sh up <id>  spin up a scenario or config directly
#   ./lab.sh destroy <id>  tear it down
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ── globals ──────────────────────────────────────────────────────────────
STATE_DIR="$HOME/.rh-dojo"
STATE_FILE="$STATE_DIR/state.json"
SSH_KEY="${RH_DOJO_SSH_KEY:-$HOME/.ssh/id_ed25519}"
RENDER_DIR=""

# colours — tput when connected to a terminal, raw escapes otherwise
if [[ -t 1 ]]; then
  _BOLD="$(tput bold 2>/dev/null || printf '\033[1m')"
  _DIM="$(tput dim 2>/dev/null || printf '\033[2m')"
  _RED="$(tput setaf 1 2>/dev/null || printf '\033[31m')"
  _GRN="$(tput setaf 2 2>/dev/null || printf '\033[32m')"
  _YEL="$(tput setaf 3 2>/dev/null || printf '\033[33m')"
  _CYN="$(tput setaf 6 2>/dev/null || printf '\033[36m')"
  _RST="$(tput sgr0 2>/dev/null || printf '\033[0m')"
else
  _BOLD=""; _DIM=""; _RED=""; _GRN=""; _YEL=""; _CYN=""; _RST=""
fi

# box chars
_H="─"; _V="│"; _TL="┌"; _TR="┐"; _BL="└"; _BR="┘"
_CL="├"; _CR="┤"; _TCB="┬"; _BCB="┴"; _CS="┼"

# ── helpers ──────────────────────────────────────────────────────────────
die() { printf '%b\n' "${_RED}error: $*${_RST}" >&2; exit 1; }

require_brew() {
  command -v brew >/dev/null || die "Homebrew required. Install from https://brew.sh"
}

require_lima() {
  command -v limactl >/dev/null || {
    echo "Lima not found. Install with: brew install lima" >&2
    echo "Then: limactl start --name=template template://fedora  (accept & stop immediately — caches the image)" >&2
    die "limactl missing"
  }
}

require_ssh_key() {
  if [[ ! -f "$SSH_KEY" ]]; then
    die "SSH key not found at $SSH_KEY. Set RH_DOJO_SSH_KEY or run: ssh-keygen -t ed25519"
  fi
  SSH_PUBKEY="$(< "${SSH_KEY}.pub")"
  # base64-encode the private key so it survives YAML / shell interpolation safely.
  SSH_PRIVKEY_B64="$(base64 < "$SSH_KEY")"
}

# ── state management (JSON via python3) ──────────────────────────────────
init_state() {
  mkdir -p "$STATE_DIR"
  if [[ ! -f "$STATE_FILE" ]]; then
    /usr/bin/python3 -c "
import json
state = {'version': 1, 'instances': {}, 'completions': {}}
json.dump(state, open('$STATE_FILE', 'w'), indent=2)
"
  fi
}

read_state() {
  /usr/bin/python3 -c "
import json, sys
state = json.load(open('$STATE_FILE'))
key = sys.argv[1] if len(sys.argv) > 1 else ''
if key:
    v = state
    for k in key.split('.'):
        v = v.get(k, {})
    print(json.dumps(v) if isinstance(v, dict) else json.dumps(v))
else:
    print(json.dumps(state))
" "$@"
}

write_state() {
  local path="$1" value="$2"
  /usr/bin/python3 -c "
import json
state = json.load(open('$STATE_FILE'))
parts = '$path'.split('.')
v = state
for k in parts[:-1]:
    v = v.setdefault(k, {})
v[parts[-1]] = json.loads('''$value''')
json.dump(state, open('$STATE_FILE', 'w'), indent=2)
"
}

# ── JSON parsing ─────────────────────────────────────────────────────────
# Read a field from a JSON file (nested key like "vms.control.cpus")
json_get() {
  local file="$1" key="$2"
  /usr/bin/python3 -c "
import json
data = json.load(open('$file'))
parts = '$key'.split('.')
for p in parts:
    data = data[p]
print(data)
"
}

# List all scenario/config IDs with their metadata
list_scenarios() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    for f in "$dir"/*.json; do
      [[ -f "$f" ]] || continue
      local id; id="$(basename "$f" .json)"
      local name; name="$(json_get "$f" name)"
      local desc; desc="$(json_get "$f" description)"
      echo "$id|$name|$desc"
    done
  fi
}

# ── Lima operations ──────────────────────────────────────────────────────
lima_instance_name() { echo "rh-${1}"; }

lima_exists() { limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$1"; }

lima_status() {
  limactl list --format json 2>/dev/null \
    | /usr/bin/python3 -c "
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
for inst in data:
    if inst.get('name') == name:
        print(inst.get('status', 'unknown'))
        sys.exit(0)
print('absent')
" "$1" 2>/dev/null || echo "absent"
}

lima_ssh_port() {
  limactl list --format json 2>/dev/null \
    | /usr/bin/python3 -c "
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
for inst in data:
    if inst.get('name') == name:
        port = inst.get('sshLocalPort', 0)
        print(port or 0)
        sys.exit(0)
print(0)
" "$1"
}

# Wait for SSH to become available on the given port
wait_for_ssh() {
  local port="$1" timeout="${2:-120}"
  local start; start="$(date +%s)"
  printf "  waiting for SSH on port %s " "$port"
  while true; do
    if ssh -q -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 \
      -i "$SSH_KEY" -p "$port" root@localhost "exit" 2>/dev/null; then
      printf " %bready%b\n" "$_GRN" "$_RST"
      return 0
    fi
    local now; now="$(date +%s)"
    if (( now - start > timeout )); then
      printf " %btimed out%b\n" "$_RED" "$_RST"
      return 1
    fi
    printf "."
    sleep 2
  done
}

# Spin up a single VM
launch_vm() {
  local scenario_id="$1" vm_name="$2" cpus="$3" mem="$4" disk="$5" role="$6"
  local inst_name; inst_name="$(lima_instance_name "${scenario_id}-${vm_name}")"

  if lima_exists "$inst_name"; then
    local st; st="$(lima_status "$inst_name")"
    if [[ "$st" == "Running" ]]; then
      local port; port="$(lima_ssh_port "$inst_name")"
      echo "  $_DIM$inst_name already running (port $port)$_RST"
      write_state "instances.$inst_name" "{\"scenario\":\"$scenario_id\",\"vm\":\"$vm_name\",\"port\":$port,\"role\":\"$role\"}"
      return 0
    fi
  fi

  # Deterministic SSH port from instance name — must match the template render below.
  local lima_port; lima_port="$(
    /usr/bin/python3 -c "
inst_name = '${inst_name}'
port = 50000 + (sum(ord(c) for c in inst_name) % 10000)
print(port)
"
  )"

  # Render Lima YAML from template
  local template; template="$SCRIPT_DIR/lima/${role}.yaml"
  [[ -f "$template" ]] || template="$SCRIPT_DIR/lima/node.yaml"

  mkdir -p "$RENDER_DIR"
  local rendered; rendered="$RENDER_DIR/$inst_name.yaml"

  /usr/bin/python3 - "$template" "$rendered" "$cpus" "$mem" "$disk" "$SSH_PUBKEY" "$lima_port" "$SSH_PRIVKEY_B64" <<'PY'
import sys
src, dst, cpus, mem, disk, pubkey, port, privkey_b64 = sys.argv[1:9]
content = open(src).read()
content = content.replace('{{CPUS}}', cpus)
content = content.replace('{{MEMORY}}', mem)
content = content.replace('{{DISK}}', disk)
content = content.replace('{{SSH_PUBKEY}}', pubkey)
content = content.replace('{{SSH_PORT}}', port)
content = content.replace('{{SSH_PRIVKEY_B64}}', privkey_b64)
open(dst, 'w').write(content)
PY

  echo "  launching $_CYN$inst_name$_RST ($cpus cpu / $mem / $disk, port $lima_port) ..."

  # Run synchronously — we wait for SSH below anyway.
  if ! limactl start --name="$inst_name" --tty=false "$rendered" >/dev/null 2>&1; then
    echo "  ${_RED}limactl start failed${_RST}"
    return 1
  fi

  wait_for_ssh "$lima_port" 180 || {
    echo "  ${_RED}SSH never came up${_RST}"
    return 1
  }

  write_state "instances.$inst_name" "{\"scenario\":\"$scenario_id\",\"vm\":\"$vm_name\",\"port\":$lima_port,\"role\":\"$role\"}"
  return 0
}

# Spin up all VMs for a scenario or config
spin_up() {
  local type="$1" id="$2"      # type = "scenario" or "config"
  local file="$SCRIPT_DIR/${type}s/${id}.json"
  [[ -f "$file" ]] || die "no such $type: $id"

  local name; name="$(json_get "$file" name)"
  local vms; vms="$(json_get "$file" vms)"

  echo
  echo "  $_BOLD$name$_RST"

  # Check for already-running instances
  local vm_keys; vm_keys="$(/usr/bin/python3 -c "
import json
vms = json.loads('''$vms''')
print(' '.join(vms.keys()))
")"

  RENDER_DIR="$(mktemp -d)"

  for vk in $vm_keys; do
    local cpus; cpus="$(/usr/bin/python3 -c "
import json
vms = json.loads('''$vms''')
print(vms['$vk']['cpus'])
")"
    local mem; mem="$(/usr/bin/python3 -c "
import json
vms = json.loads('''$vms''')
print(vms['$vk']['memory'])
")"
    local disk; disk="$(/usr/bin/python3 -c "
import json
vms = json.loads('''$vms''')
print(vms['$vk']['disk'])
")"
    local role; role="$(/usr/bin/python3 -c "
import json
vms = json.loads('''$vms''')
print(vms['$vk']['role'])
")"
    launch_vm "$id" "$vk" "$cpus" "$mem" "$disk" "$role"
  done

  echo
  echo "  ${_GRN}ready.${_RST} SSH example:"
  local first_port; first_port="$(read_state | /usr/bin/python3 -c "
import json, sys
state = json.load(sys.stdin)
for name, info in state.get('instances', {}).items():
    if info.get('scenario') == '$id':
        print(info.get('port', ''))
        break
")"
  if [[ -n "$first_port" ]]; then
    echo "    ssh -i ~/.ssh/id_ed25519 -p $first_port root@localhost    # first VM"
  fi
  echo
  read -r -p "  Press enter to continue...  " _
  rm -rf "${RENDER_DIR:-}"
}

# Destroy all VMs for a scenario or config
destroy_vms() {
  local id="$1"
  local inst_names; inst_names="$(/usr/bin/python3 -c "
import json, sys
state = json.load(open('$STATE_FILE'))
for name, info in state.get('instances', {}).items():
    if info.get('scenario') == '$id':
        print(name)
" 2>/dev/null)"

  if [[ -z "$inst_names" ]]; then
    echo "  no running instances for '$id'"
    read -r -p "  Press enter to continue...  " _
    return
  fi

  echo
  echo "  ${_RED}This will destroy:${_RST}"
  for n in $inst_names; do echo "    $n"; done
  echo
  read -r -p "  Type 'yes' to confirm: " reply
  [[ "$reply" == "yes" ]] || { echo "  aborted."; return; }

  for n in $inst_names; do
    printf "  deleting %s ... " "$n"
    limactl delete --force "$n" >/dev/null 2>&1 && printf "done\n" || printf "failed\n"
    write_state "instances.$n" "null"
  done
  # clean null entries
  /usr/bin/python3 -c "
import json
state = json.load(open('$STATE_FILE'))
state['instances'] = {k: v for k, v in state.get('instances', {}).items() if v is not None}
json.dump(state, open('$STATE_FILE', 'w'), indent=2)
"
  echo
  read -r -p "  Press enter to continue...  " _
}

# Mark a scenario as completed
mark_complete() {
  local id="$1"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_state "completions.$id" "{\"completed\":true,\"completed_at\":\"$now\"}"
  echo "  ${_GRN}✓${_RST} marked '$id' as complete"
  read -r -p "  Press enter to continue...  " _
}

# Toggle completion (mark/unmark)
toggle_complete() {
  local id="$1"
  local completed; completed="$(read_state "completions.$id.completed")"
  if [[ "$completed" == "true" ]]; then
    write_state "completions.$id" "null"
    # clean if empty
    echo "  marked '$id' as incomplete"
  else
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    write_state "completions.$id" "{\"completed\":true,\"completed_at\":\"$now\"}"
    echo "  ${_GRN}✓${_RST} marked '$id' as complete"
  fi
  read -r -p "  Press enter to continue...  " _
}

# Run a completion check script
run_completion_check() {
  local id="$1"
  local check_script="$SCRIPT_DIR/completions/$id.sh"
  [[ -f "$check_script" ]] || { echo "  no check script for '$id'"; return 1; }

  # collect SSH ports for running VMs of this scenario
  local ports; ports="$(/usr/bin/python3 -c "
import json
state = json.load(open('$STATE_FILE'))
pairs = []
for name, info in state.get('instances', {}).items():
    if info.get('scenario') == '$id':
        pairs.append(f\"{info['vm']}:{info['port']}\")
print(','.join(pairs))
" 2>/dev/null)"

  if [[ -z "$ports" ]]; then
    echo "  ${_YEL}no VMs running for '$id' — spin up first${_RST}"
    read -r -p "  Press enter to continue...  " _
    return 1
  fi

  echo "  running completion check ..."
  SSH_PORTS="$ports" bash "$check_script" && {
    echo "  ${_GRN}✓ all checks passed${_RST}"
    mark_complete "$id"
    return 0
  } || {
    echo "  ${_RED}✗ checks failed${_RST}"
    read -r -p "  Press enter to continue...  " _
    return 1
  }
}

# ── TUI rendering ────────────────────────────────────────────────────────
box_top() {
  local width="${1:-42}" text="${2:-}"
  printf '%b' "$_CYN$_TL"
  printf '%*s' "$((width-2))" '' | tr ' ' "$_H"
  printf '%b\n' "$_TR$_RST"
  if [[ -n "$text" ]]; then
    local pad_left=$(( (width - ${#text} - 2) / 2 ))
    local pad_right=$(( width - 2 - ${#text} - pad_left ))
    printf '%b' "$_CYN$_V$_RST"
    printf '%*s' "$pad_left" ''
    printf '%b%s%b' "$_BOLD" "$text" "$_RST"
    printf '%*s' "$pad_right" ''
    printf '%b\n' "$_CYN$_V$_RST"
  fi
}

box_mid() {
  local width="${1:-42}"
  printf '%b' "$_CYN$_CL"
  printf '%*s' "$((width-2))" '' | tr ' ' "$_H"
  printf '%b\n' "$_CR$_RST"
}

box_bot() {
  local width="${1:-42}"
  printf '%b' "$_CYN$_BL"
  printf '%*s' "$((width-2))" '' | tr ' ' "$_H"
  printf '%b\n' "$_BR$_RST"
}

box_line() {
  local width="${1:-42}" text="${2:-}"
  printf '%b' "$_CYN$_V$_RST"
  printf ' %s' "$text"
  printf '%*s' "$((width - ${#text} - 3))" ''
  printf '%b\n' "$_CYN$_V$_RST"
}

box_line_center() {
  local width="${1:-42}" text="${2:-}"
  local pad_left=$(( (width - ${#text} - 2) / 2 ))
  local pad_right=$(( width - 2 - ${#text} - pad_left ))
  printf '%b' "$_CYN$_V$_RST"
  printf '%*s' "$pad_left" ''
  printf '%s' "$text"
  printf '%*s' "$pad_right" ''
  printf '%b\n' "$_CYN$_V$_RST"
}

# Completion indicator
comp_icon() {
  local id="$1"
  local completed; completed="$(read_state "completions.$id.completed" 2>/dev/null || echo "false")"
  if [[ "$completed" == "true" ]]; then
    printf '%b[%b✓%b]%b' "$_GRN" "$_BOLD" "$_RST" "$_RST"
  else
    printf '%b[ ]%b' "$_DIM" "$_RST"
  fi
}

# ── menu screens ─────────────────────────────────────────────────────────
W=50

draw_main() {
  clear
  local sep="---------------------------------------------------"

  # build scenario & config lists into indexed arrays
  local -a items=()
  local -a ids=()
  local -a kinds=()

  # scenarios
  if [[ -d "$SCRIPT_DIR/scenarios" ]]; then
    for f in "$SCRIPT_DIR/scenarios"/*.json; do
      [[ -f "$f" ]] || continue
      ids+=("$(basename "$f" .json)")
      items+=("$(json_get "$f" name)")
      kinds+=("scenario")
    done
  fi

  # quick configs
  if [[ -d "$SCRIPT_DIR/configs" ]]; then
    for f in "$SCRIPT_DIR/configs"/*.json; do
      [[ -f "$f" ]] || continue
      ids+=("$(basename "$f" .json)")
      items+=("$(json_get "$f" name)")
      kinds+=("config")
    done
  fi

  box_top "$W" "rh-dojo"
  box_line_center "$W" "Red Hat Learning Lab"
  box_line_center "$W" "Apple Silicon · Lima · Fedora aarch64"
  box_mid "$W"

  # Show running instances summary
  local running; running="$(/usr/bin/python3 -c "
import json
state = json.load(open('$STATE_FILE'))
count = len([v for v in state.get('instances', {}).values() if v is not None])
print(count)
" 2>/dev/null || echo 0)"
  if (( running > 0 )); then
    box_line "$W" "${_GRN}$running instance(s) running${_RST}"
    box_mid "$W"
  fi

  local num=0
  local show_section="scenarios"

  for i in "${!items[@]}"; do
    local kind="${kinds[$i]}"

    # Show section headers
    if [[ "$kind" == "config" && "$show_section" == "scenarios" ]]; then
      show_section="configs"
      box_line "$W" ""
      box_line "$W" "${_BOLD}Quick Configs${_RST}"
    fi
    if [[ "$kind" == "scenario" && "$show_section" == "scenarios" && "$num" -eq 0 ]]; then
      box_line "$W" "${_BOLD}Scenarios${_RST}"
    fi

    ((num++))
    local icon; icon="$(comp_icon "${ids[$i]}")"
    box_line "$W" "$(printf '%*s' 2 '')${_BOLD}$num${_RST}  $icon ${items[$i]}"
  done

  box_mid "$W"
  box_line "$W" "$(printf '%*s' 2 '')${_BOLD}m${_RST}  Manage running instances"
  box_line "$W" "$(printf '%*s' 2 '')${_BOLD}q${_RST}  Quit"
  box_bot "$W"
  echo
  printf "  Choice [1-$num, m, q]: "
}

draw_manage() {
  local id="$1" kind="$2"
  local file="$SCRIPT_DIR/${kind}s/${id}.json"
  local name; name="$(json_get "$file" name)" 2>/dev/null || name="$id"

  # Check running state
  local running_count; running_count="$(/usr/bin/python3 -c "
import json
state = json.load(open('$STATE_FILE'))
count = 0
for info in state.get('instances', {}).values():
    if info is not None and info.get('scenario') == '$id':
        count += 1
print(count)
" 2>/dev/null || echo 0)"

  local status_text
  if (( running_count > 0 )); then
    status_text="${_GRN}$running_count VM(s) running${_RST}"
  else
    status_text="${_DIM}not running${_RST}"
  fi

  clear
  box_top "$W" "$name"
  box_line_center "$W" "Status: $status_text"

  # Show running VMs with SSH ports
  /usr/bin/python3 -c "
import json
state = json.load(open('$STATE_FILE'))
for inst_name, info in state.get('instances', {}).items():
    if info is not None and info.get('scenario') == '$id':
        print(f\"    {info['vm']}  : ssh -p {info['port']} root@localhost  ({info['role']})\")
" 2>/dev/null | while IFS= read -r line; do
    box_line "$W" "$line"
  done

  local completed; completed="$(read_state "completions.$id.completed" 2>/dev/null || echo "false")"
  if [[ "$completed" == "true" ]]; then
    box_line "$W" ""
    box_line "$W" "  ${_GRN}✓ completed${_RST}"
  fi

  box_mid "$W"
  if (( running_count == 0 )); then
    box_line "$W" "$(printf '%*s' 2 '')${_BOLD}u${_RST}  Spin up VMs"
  else
    box_line "$W" "$(printf '%*s' 2 '')${_BOLD}s${_RST}  SSH to a VM"
    box_line "$W" "$(printf '%*s' 2 '')${_BOLD}x${_RST}  Destroy VMs"
  fi
  box_line "$W" "$(printf '%*s' 2 '')${_BOLD}c${_RST}  $(if [[ "$completed" == "true" ]]; then echo "Unmark"; else echo "Mark "; fi) as complete"

  # Show check option if a check script exists
  if [[ -f "$SCRIPT_DIR/completions/$id.sh" ]]; then
    box_line "$W" "$(printf '%*s' 2 '')${_BOLD}t${_RST}  Run completion check"
  fi

  box_mid "$W"
  box_line "$W" "$(printf '%*s' 2 '')${_BOLD}b${_RST}  Back to main menu"
  box_bot "$W"
  echo
  printf "  Choice: "
}

draw_ssh_submenu() {
  local id="$1"
  clear
  box_top "$W" "SSH to VM"

  local insts; insts="$(/usr/bin/python3 -c "
import json
state = json.load(open('$STATE_FILE'))
for inst_name, info in state.get('instances', {}).items():
    if info is not None and info.get('scenario') == '$id':
        print(f\"{info['vm']}|{info['port']}|{inst_name}\")
" 2>/dev/null)"

  local n=0
  local -a vm_names=()
  local -a vm_ports=()
  while IFS='|' read -r vname vport vinst; do
    [[ -z "$vname" ]] && continue
    ((n++))
    vm_names+=("$vname")
    vm_ports+=("$vport")
    box_line "$W" "$(printf '%*s' 2 '')${_BOLD}$n${_RST}  $vname (port $vport)"
  done <<< "$insts"

  box_mid "$W"
  box_line "$W" "$(printf '%*s' 2 '')${_BOLD}b${_RST}  Back"
  box_bot "$W"
  echo
  printf "  SSH to which VM? [1-$n, b]: "

  read -r choice
  case "$choice" in
    [1-9]*)  # Allow single digit
      local idx=$((choice - 1))
      if [[ -n "${vm_names[$idx]:-}" ]]; then
        echo
        echo "  Connecting to ${vm_names[$idx]} ..."
        exec ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "${vm_ports[$idx]}" root@localhost
      fi
      ;;
  esac
}

draw_manage_instances() {
  clear
  box_top "$W" "Running Instances"

  local insts; insts="$(/usr/bin/python3 -c "
import json
state = json.load(open('$STATE_FILE'))
for inst_name, info in sorted(state.get('instances', {}).items()):
    if info is not None:
        print(f\"{info['scenario']}|{info['vm']}|{info['port']}|{inst_name}|{info['role']}\")
" 2>/dev/null)"

  if [[ -z "$insts" ]]; then
    box_line "$W" "  ${_DIM}no running instances${_RST}"
  else
    while IFS='|' read -r sid vname vport vinst vrole; do
      [[ -z "$sid" ]] && continue
      box_line "$W" "  ${_BOLD}$vinst${_RST}  $vrole  port $vport  ($sid)"
    done <<< "$insts"
  fi

  box_mid "$W"
  box_line "$W" "$(printf '%*s' 2 '')${_BOLD}d${_RST}  Destroy all running instances"
  box_line "$W" "$(printf '%*s' 2 '')${_BOLD}b${_RST}  Back to main menu"
  box_bot "$W"
  echo
  printf "  Choice: "

  read -r choice
  case "$choice" in
    d|D)
      echo
      local r
      read -r -p "  ${_RED}Destroy ALL running instances?${_RST} Type 'yes all': " r
      if [[ "$r" == "yes all" ]]; then
        while IFS='|' read -r sid vname vport vinst vrole; do
          [[ -z "$vinst" ]] && continue
          limactl delete --force "$vinst" 2>/dev/null || true
        done <<< "$insts"
        write_state "instances" "{}"
        echo "  all destroyed."
      fi
      read -r -p "  Press enter to continue...  " _
      ;;
  esac
}

# ── main loop ────────────────────────────────────────────────────────────
menu_main() {
  while true; do
    draw_main
    read -r choice
    case "$choice" in
      q|Q) echo; exit 0 ;;
      m|M) menu_manage_instances ;;
      *)
        # check if it's a number
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
          # remap to id
          local idx=$((choice - 1))
          # rebuild the list
          local -a all_ids=()
          if [[ -d "$SCRIPT_DIR/scenarios" ]]; then
            for f in "$SCRIPT_DIR/scenarios"/*.json; do
              [[ -f "$f" ]] || continue
              all_ids+=("scenario|$(basename "$f" .json)")
            done
          fi
          if [[ -d "$SCRIPT_DIR/configs" ]]; then
            for f in "$SCRIPT_DIR/configs"/*.json; do
              [[ -f "$f" ]] || continue
              all_ids+=("config|$(basename "$f" .json)")
            done
          fi

          if [[ -n "${all_ids[$idx]:-}" ]]; then
            local kind="${all_ids[$idx]%%|*}"
            local sid="${all_ids[$idx]##*|}"
            menu_scenario "$sid" "$kind"
          fi
        fi
        ;;
    esac
  done
}

menu_scenario() {
  local id="$1" kind="$2"
  while true; do
    draw_manage "$id" "$kind"
    read -r choice
    case "$choice" in
      b|B) return ;;
      u|U)
        # check if any VMs are already running
        local running; running="$(/usr/bin/python3 -c "
import json
state = json.load(open('$STATE_FILE'))
count = 0
for info in state.get('instances', {}).values():
    if info is not None and info.get('scenario') == '$id':
        count += 1
print(count)
" 2>/dev/null || echo 0)"
        if (( running > 0 )); then
          echo "  already running. Destroy first."
          read -r -p "  Press enter to continue...  " _
        else
          spin_up "$kind" "$id"
        fi
        ;;
      s|S) draw_ssh_submenu "$id" ;;
      x|X) destroy_vms "$id" ;;
      c|C) toggle_complete "$id" ;;
      t|T) run_completion_check "$id" ;;
    esac
  done
}

menu_manage_instances() { draw_manage_instances; }

# ── CLI mode (non-interactive) ───────────────────────────────────────────
cli_up() {
  local id="$1"
  local file
  if [[ -f "$SCRIPT_DIR/scenarios/$id.json" ]]; then
    spin_up "scenario" "$id"
  elif [[ -f "$SCRIPT_DIR/configs/$id.json" ]]; then
    spin_up "config" "$id"
  else
    die "unknown scenario or config: $id"
  fi
}

cli_destroy() {
  local id="$1"
  destroy_vms "$id"
}

# ── entry point ──────────────────────────────────────────────────────────
main() {
  require_brew
  require_lima
  require_ssh_key
  init_state

  case "${1:-menu}" in
    menu)     menu_main ;;
    up)       cli_up "${2:?usage: lab.sh up <scenario-or-config-id>}" ;;
    destroy)  cli_destroy "${2:?usage: lab.sh destroy <scenario-or-config-id>}" ;;
    *)        echo "usage: lab.sh [menu|up <id>|destroy <id>]" >&2; exit 1 ;;
  esac
}

main "$@"
