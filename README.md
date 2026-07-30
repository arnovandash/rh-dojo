# rh-dojo

Red Hat system administration & Ansible automation lab for Apple Silicon Macs. Scenario-based, minimal provisioning with [Lima](https://github.com/lima-vm/lima) + Fedora aarch64.

**Companion to [k8s-dojo](https://github.com/arnovan/k8s-dojo).**

## Why

RHCSA and RHCE practice requires RHEL-like systems with proper systemd, SELinux, firewalld, and Ansible. Red Hat doesn't provide RHEL for Apple Silicon, but Fedora (RHEL's upstream) boots natively on aarch64 Macs and shares the same toolchain. Lima gives us lightweight, scriptable VMs without VirtualBox or Vagrant headaches.

## Quickstart

```bash
# Prerequisites
brew install lima

# Cache the Fedora image (first run only — ~45s)
limactl start --name=template template://fedora
limactl stop template && limactl delete template

# Launch the lab
cd rh-dojo
./lab.sh
```

## How it works

- **Scenarios** — predefined exercises with specific VM topologies and learning objectives
- **Quick configs** — ad-hoc VM groups for unstructured practice
- **Completion tracking** — persistent state at `~/.rh-dojo/state.json`, visible in the menu

Only the VMs you request get provisioned. Nothing pre-baked beyond root SSH and base packages.

## Scenarios

| ID | VMs | Content |
|----|-----|---------|
| `ansible-basics` | 3 (control + 2 nodes) | Ad-hoc commands, modules, inventory |
| `ansible-playbooks` | 3 (control + 2 nodes) | Playbooks, variables, facts, handlers |
| `ansible-roles` | 4 (control + 3 nodes) | Roles, collections, ansible-galaxy |
| `full-exam` | 5 (control + 4 nodes) | Timed full exam simulation |

## Quick Configs

| ID | VMs | Use case |
|----|-----|----------|
| `single-node` | 1 | General practice, RHCSA tasks |
| `control+2nodes` | 3 | Ad-hoc Ansible practice |
| `control+4nodes` | 5 | Exam-sim topology (no time pressure) |

## VM specs

| Role | Default | Notes |
|------|---------|-------|
| Control node | 2 CPU / 2 GiB / 20 GB | Ansible-core pre-installed |
| Managed node | 1 CPU / 1 GiB / 10 GB | Python + selinux bindings |
| Standalone | 2 CPU / 2 GiB / 20 GB | General RHCSA practice |

## Completion checks

Some scenarios include automated check scripts in `completions/`. These SSH into your running VMs and verify that learning objectives have been met. Select **t** (Run completion check) from the scenario menu, or mark completion manually with **c**.

## CLI mode

```bash
./lab.sh up ansible-basics       # spin up a specific scenario
./lab.sh destroy ansible-basics  # tear it down
./lab.sh                          # interactive menu (default)
```

## Project structure

```
rh-dojo/
├── lab.sh                # Main TUI + lifecycle script
├── scenarios/            # JSON scenario definitions
├── configs/              # JSON quick-config definitions
├── completions/          # Per-scenario completion check scripts
├── lima/                 # Lima YAML templates (control + node)
└── README.md
```

## Requirements

- Apple Silicon Mac (arm64)
- macOS 14+
- [Homebrew](https://brew.sh)
- [Lima](https://github.com/lima-vm/lima) (`brew install lima`)
- SSH keypair at `~/.ssh/id_ed25519` (override with `RH_DOJO_SSH_KEY`)
- ~30 GB free disk (VMs are thin-provisioned, actual usage is less)

## License

MIT — Copyright (c) 2026 Arno van Wyk
