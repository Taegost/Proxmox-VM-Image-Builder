# CLAUDE.md — proxmox-vm-image-builder

This file provides context and instructions for Claude Code when working in this repository.

---

## Project Purpose

This repository builds standardized VM images and Proxmox templates using:
- **Packer** (HashiCorp) — orchestrates the build and produces the Proxmox template
- **cloud-init / autoinstall** — handles unattended OS installation
- **Ansible** — runs baseline provisioning inside Packer (not post-clone configuration)
- **GitHub Actions** — CI/CD pipeline with scheduled monthly rebuilds and manual dispatch

The output is a Proxmox VM template that can be cloned and further configured by Ansible post-clone. This repo is intentionally scoped to image building only — it does not provision or configure application workloads.

**Currently supported images:**
- Ubuntu 24.04 LTS (Noble Numbat)

---

## Repository Structure

Each supported image lives in its own subdirectory under `packer/` and `ansible/`, keeping image-specific config isolated and making it straightforward to add new images in the future.

```
proxmox-vm-image-builder/
├── packer/
│   ├── ubuntu-2404/
│   │   ├── ubuntu-2404.pkr.hcl   # Packer build definition
│   │   ├── variables.pkr.hcl     # Non-secret variable declarations
│   │   └── http/
│   │       ├── user-data          # Cloud-init autoinstall config
│   │       └── meta-data          # Required by cloud-init (intentionally empty)
│   └── <future-image>/            # Additional images follow the same pattern
├── ansible/
│   ├── ubuntu-2404/
│   │   └── provision.yml          # Packer-time provisioning playbook (baseline only)
│   └── roles/
│       └── baseline/              # Hardening, packages, SSH config (shared across images)
├── .github/
│   └── workflows/
│       └── build-template.yml     # GitHub Actions pipeline
├── docs/
│   └── architecture.md           # Bake-vs-configure rationale and decisions
├── CLAUDE.md                      # This file
└── README.md
```

---

## Architecture Decisions

### The Bake vs. Configure Line

**Baked into the image (Packer does this — applies to every VM regardless of distro):**
- Minimal server install of the target OS
- All pending package updates at build time
- `qemu-guest-agent` (required for Proxmox integration)
- `cloud-init` (handles per-clone customization)
- Core tools: `curl`, `wget`, `git`, `vim`, `htop`, `unzip`, `ca-certificates`
- `python3`, `python3-pip` (Ansible dependency)
- `fail2ban` (baseline security)
- SSH hardening (key-only auth, no root login)
- Basic sysctl hardening
- NTP/timesyncd configuration
- `ansible` service account with pre-authorized SSH key
- cloud-init configured to regenerate SSH host keys and machine-id on first clone boot

**Left for post-clone Ansible (varies by VM role):**
- Hostname and static IP (set via cloud-init at clone time)
- Application packages and configuration
- Cluster joining (k3s, etc.)
- Workload-specific firewall rules
- NFS mounts
- Any secrets or credentials

The guiding principle: **the template should produce a VM that is ready to be configured, not fully configured for a purpose.**

---

## Tooling & Versions

- **Packer plugin:** `github.com/hashicorp/proxmox` >= 1.1.8
- **Packer plugin:** `github.com/hashicorp/ansible` >= 1.1.2
- **Supported images:** See "Currently supported images" in Project Purpose — update ISO URLs and checksums when new point releases drop
- **GitHub Actions runner:** `ubuntu-latest` (GitHub-hosted) with Tailscale ephemeral auth for private network access

---

## Secrets & Credentials

**Never commit secrets to this repository.** All credentials are passed via environment variables.

In GitHub Actions, the following secrets must be configured under Settings → Secrets → Actions:
- `PROXMOX_URL` — full API URL, e.g. `https://proxmox.example.com:8006/api2/json`
- `PROXMOX_TOKEN_ID` — Packer API token ID, e.g. `packer@pve!packer-token`
- `PROXMOX_TOKEN_SECRET` — API token secret (sensitive)
- `SSH_PUBLIC_KEY` — public key pre-authorized in the template for the `ansible` user
- `TAILSCALE_AUTH_KEY` — ephemeral Tailscale auth key for runner → Proxmox connectivity

For local builds, export these as environment variables prefixed with `PKR_VAR_`:
```bash
export PKR_VAR_proxmox_url="https://..."
export PKR_VAR_proxmox_token_id="packer@pve!packer-token"
export PKR_VAR_proxmox_token_secret="..."
export PKR_VAR_ssh_public_key="ssh-ed25519 ..."
```

---

## Proxmox API Token Permissions

The Packer service account in Proxmox (`packer@pve`) needs the following privileges — no more:
```
VM.Allocate, VM.Clone, VM.Config.CDROM, VM.Config.CPU, VM.Config.Disk,
VM.Config.HWType, VM.Config.Memory, VM.Config.Network, VM.Config.Options,
VM.Monitor, VM.Audit, VM.PowerMgmt,
Datastore.AllocateSpace, Datastore.AllocateTemplate, Datastore.Audit
```

---

## Running a Local Build

```bash
cd packer/<image-name>
packer init .
packer validate .
packer build -on-error=cleanup .
```

The ISO URL must be reachable from the Proxmox host (not the machine running Packer). Packer serves the cloud-init `user-data` over a temporary HTTP server — ensure the Proxmox node can reach the machine running Packer during the build.

---

## Pipeline Triggers

The GitHub Actions workflow fires on:
1. **Push to `main`** when files under `packer/` or `ansible/` change
2. **Monthly schedule** (`cron: '0 3 1 * *'`) to pick up upstream package updates for all images
3. **Manual dispatch** (`workflow_dispatch`) for on-demand builds of a specific image

---

## Coding Conventions

- All Packer HCL files use `.pkr.hcl` extension
- Variables with no default and marked `sensitive = true` for anything secret
- Ansible roles follow the standard roles directory structure
- Shell provisioners in Packer are used only for final cleanup (cloud-init reset, machine-id truncation, apt cache clear) — all other provisioning goes in Ansible
- Keep the Ansible provisioner scope narrow: this is baseline hardening only, not application config
- When adding a new image, create a new subdirectory under both `packer/` and `ansible/` following the existing `ubuntu-2404` pattern — do not add image-specific config to shared locations

---

## What This Repo Is NOT

- Not a VM provisioner (use Terraform or `qm clone` for that)
- Not an application configuration repo (that lives in `homelab-k8s` or separate Ansible inventories)
- Not a multi-purpose config management tool — Ansible provisioning here is baseline only

---

## Related Repositories

- [`Taegost/homelab-k8s`](https://github.com/Taegost/homelab-k8s) — k3s cluster GitOps (ArgoCD app-of-apps)
