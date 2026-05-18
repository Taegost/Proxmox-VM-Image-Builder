# Proxmox VM Image Builder

Automated VM image and template builder for Proxmox using Packer, cloud-init, and Ansible — with a GitHub Actions CI/CD pipeline for scheduled rebuilds and Tailscale for secure remote access.

## What it builds

| Template | VM ID | Description |
|----------|-------|-------------|
| `ubuntu-2404` | 9000 | Ubuntu 24.04 LTS baseline |

**Ubuntu 24.04 baseline includes:**
- Full utility package set (curl, git, vim, htop, jq, rsync, net-tools, nfs-common, cifs-utils, and more)
- Automatic security patching via `unattended-upgrades` (security channel only, no auto-reboot)
- UFW firewall: default-deny incoming, SSH port 22 allowed
- SSH hardening (password auth disabled, key-only, MaxAuthTries 3)
- fail2ban with 1-hour bans
- sysctl network and kernel hardening
- NTP via systemd-timesyncd pointed at Cloudflare + Ubuntu pool
- `iac-service` service account for post-clone Ansible automation

## Prerequisites

- [Packer](https://developer.hashicorp.com/packer/install) >= 1.11
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/) >= 2.15
- Proxmox VE node reachable from your machine (directly or via Tailscale)
- A Proxmox API token with VM create/delete permissions

## GitHub Secrets

Configure these in **Settings → Secrets and variables → Actions** before the CI pipeline will run:

### Required for `validate` and `build`

| Secret | Description | How to generate |
|--------|-------------|-----------------|
| `PROXMOX_URL` | Full Proxmox API URL | `https://<hostname>:8006/api2/json` |
| `PROXMOX_TOKEN_ID` | API token identifier | `packer@pve!packer-token` (create in Proxmox UI under Datacenter → Permissions → API Tokens) |
| `PROXMOX_TOKEN_SECRET` | API token secret UUID | Shown once at token creation time |
| `SSH_PUBLIC_KEY` | ansible user's Ed25519 public key | `cat ~/.ssh/ansible_ed25519.pub` |
| `ANSIBLE_PASSWORD_HASH` | ansible user's SHA-512 password hash | `openssl passwd -6 -salt $(openssl rand -hex 8) 'YourPassword'` |
| `IAC_SERVICE_SSH_PUBLIC_KEY` | iac-service account's Ed25519 public key | `cat ~/.ssh/iac_service_ed25519.pub` |

### Required for `build` only

| Secret | Description | How to generate |
|--------|-------------|-----------------|
| `SSH_PRIVATE_KEY` | ansible user's Ed25519 private key (file content) | `cat ~/.ssh/ansible_ed25519` |
| `TAILSCALE_AUTH_KEY` | Ephemeral Tailscale auth key for CI runner | Generate in Tailscale admin console under Settings → Keys (select "Ephemeral") |

> **SSH key pairs:** The `SSH_PUBLIC_KEY` / `SSH_PRIVATE_KEY` pair is for the `ansible` build user — used by Packer during the build only. The `IAC_SERVICE_SSH_PUBLIC_KEY` is for the `iac-service` account — used by post-clone Ansible for ongoing VM management. These should be different key pairs.

## Local build

```bash
# 1. Clone and enter the image directory
cd packer/ubuntu-2404

# 2. Install Packer plugins
packer init .

# 3. Export required variables
export PKR_VAR_proxmox_url="https://yourhost:8006/api2/json"
export PKR_VAR_proxmox_token_id="packer@pve!packer-token"
export PKR_VAR_proxmox_token_secret="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export PKR_VAR_ssh_public_key="$(cat ~/.ssh/ansible_ed25519.pub)"
export PKR_VAR_ssh_private_key_file="$HOME/.ssh/ansible_ed25519"
export PKR_VAR_ansible_password_hash='$6$yoursalt$yourhash'
export PKR_VAR_iac_service_ssh_public_key="$(cat ~/.ssh/iac_service_ed25519.pub)"

# 4. Validate HCL syntax (no Proxmox connection, safe to run anywhere)
packer validate .

# 5. Build the template
packer build -on-error=cleanup .
```

`-on-error=cleanup` destroys the partially-built VM if the build fails. Without it, a failed build leaves an orphan VM in Proxmox that must be manually destroyed (`qm destroy 9000`) before the next run.

### Validate only (no secrets needed for syntax check)

```bash
packer init . && packer validate .
```

Packer validate checks HCL syntax and that all required variables have values. It does not connect to Proxmox or attempt SSH.

## CI/CD pipeline

| Trigger | Jobs | What happens |
|---------|------|--------------|
| Pull request to `main` (packer or ansible changes) | `validate` | Syntax check only — no infrastructure touched |
| Push to `main` (packer or ansible changes) | `validate` → `build` | Full template build pushed to Proxmox |
| Weekly schedule (Sunday 03:00 UTC) | `validate` → `build` | Rebuild to pick up latest security patches |
| Manual dispatch | `validate` → `build` | On-demand rebuild |

The CI runner connects to your Proxmox node via Tailscale. The build VM receives its cloud-init config through a CIDATA ISO (not an HTTP server) — this works over Tailscale without requiring a network path from the build VM back to the runner.

## Post-clone Ansible

Post-clone automation connects as `iac-service` using `~/.ssh/iac_service_ed25519`. This account has passwordless sudo (`NOPASSWD:ALL`) and is baked into every VM cloned from the template.

The `ansible` build user's sudoers entry is removed during the build cleanup — it exists only for the duration of the Packer build.

> **k3s / homelab-k8s:** UFW default-deny means k3s node initialization will fail unless your post-clone playbook opens the required cluster ports (6443, 10250, 8472/UDP, etc.) before k3s starts.
