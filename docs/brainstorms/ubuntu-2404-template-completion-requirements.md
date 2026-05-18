---
date: 2026-05-17
topic: ubuntu-2404-template-completion
---

# Ubuntu 24.04 Template: Baseline Completion

## Summary

Complete the ubuntu-2404 Packer template definition with an expanded utility package set, automatic security patching via unattended-upgrades (no auto-reboot), and a UFW baseline firewall allowing SSH only. Existing Packer structure, cloud-init autoinstall, and Ansible hardening tasks are confirmed as-is.

---

## Problem Frame

The ubuntu-2404 image definition was committed as scaffolding — the structure is in place but three aspects of a production-ready homelab baseline are absent: a complete package set, ongoing security patch delivery to running VMs, and a baseline firewall. VMs cloned from the current template will drift unpatched after first boot, have no firewall, and are missing common utilities needed for everyday homelab use.

---

## Requirements

**Package baseline**

- R1. The user-data packages list must include: `ca-certificates`, `cifs-utils`, `curl`, `dnsutils`, `fail2ban`, `git`, `haveged`, `htop`, `jq`, `logrotate`, `nano`, `ncdu`, `net-tools`, `nfs-common`, `python3`, `python3-passlib`, `python3-pip`, `qemu-guest-agent`, `rsync`, `screen`, `traceroute`, `unzip`, `vim`, `wget`.

**Automatic security updates**

- R2. The Ansible provisioner must install and configure `unattended-upgrades` to apply security-channel updates automatically on running VMs.
- R3. `unattended-upgrades` must NOT be configured to automatically reboot; reboots (e.g., after kernel updates) remain a manual operator action.

**Baseline firewall**

- R5. The Ansible provisioner must install and enable UFW with a default-deny incoming policy.
- R6. UFW must include a pre-configured allow rule for SSH (port 22/tcp) so that post-clone SSH access works without additional firewall configuration.
- R7. No other inbound rules are configured at the template level; all workload-specific ports are left to post-clone Ansible runs.

---

## Acceptance Examples

- AE1. **Covers R5, R6, R7.** Given a freshly cloned VM with no post-clone configuration, when a user attempts SSH on port 22, the connection succeeds; when a connection is attempted on any other inbound port, UFW blocks it.
- AE2. **Covers R2, R3.** Given a running VM cloned from the template, when the Ubuntu security repository publishes a non-kernel security update, unattended-upgrades applies it automatically without rebooting; when a kernel update is published, the update is downloaded and staged but the VM does not reboot until an operator does so manually.

---

## Success Criteria

- A VM cloned from the template can be reached via SSH immediately without additional firewall configuration.
- `ufw status` on a cloned VM shows: `Status: active`, default incoming `deny`, port 22 `ALLOW`.
- `unattended-upgrades --dry-run` on a cloned VM exits successfully and reports that security updates would be applied.
- `packer validate` passes for ubuntu-2404 without errors.
- A full `packer build` completes end-to-end, producing a Proxmox template.

---

## Scope Boundaries

- CIS Benchmark compliance and auditd — pragmatic hardening is the target; audit-grade controls are out of scope.
- Workload-specific firewall rules (e.g., k3s cluster ports) — belong in homelab-k8s post-clone playbooks, not in the template.
- Application-level packages and role-specific configuration — baseline only.
- Additional image variants or other distros.

---

## Key Decisions

- **UFW enabled at template level:** Enforces a hardened starting point. Trade-off: post-clone Ansible in homelab-k8s must open workload ports before services start, or those services will fail to initialize.
- **No auto-reboot for unattended-upgrades:** Security patches apply silently; kernel updates are staged but reboots remain a manual operator action. Trade-off: VMs may run a stale kernel until the operator reboots.

---

## Dependencies / Assumptions

- **homelab-k8s dependency:** UFW default-deny means k3s node initialization will fail unless the post-clone Ansible playbook in homelab-k8s opens required cluster ports (e.g., 6443, 10250, 8472/UDP) before k3s starts. This repo does not own that playbook; the dependency must be tracked in homelab-k8s.
- **haveged alongside virtio-rng:** Modern QEMU provides a `virtio-rng` entropy source. `haveged` is included per operator preference and is assumed harmless alongside it.

---

