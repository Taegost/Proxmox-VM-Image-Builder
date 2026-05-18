---
date: 2026-05-17
type: feat
status: completed
origin: docs/brainstorms/ubuntu-2404-template-completion-requirements.md
---

# feat: Complete ubuntu-2404 baseline template

## Summary

Completes the ubuntu-2404 Packer template with three additions: an expanded utility package set baked in at install time, `unattended-upgrades` configured for automatic security patching without auto-reboot, and UFW enabled with default-deny incoming and SSH-only allow. All existing Packer structure, cloud-init autoinstall, and Ansible hardening tasks remain unchanged.

---

## Problem Frame

The ubuntu-2404 image definition was committed as scaffolding. The structure is correct but VMs cloned from the current template drift unpatched after first boot, have no firewall, and lack common utilities. This work closes those three gaps. (see origin: `docs/brainstorms/ubuntu-2404-template-completion-requirements.md`)

---

## Key Technical Decisions

- **UFW via `community.general.ufw`:** The existing `provision.yml` uses only `ansible.builtin.*` modules. Configuring UFW idiomatically and with idempotency requires the `community.general` collection. The plan adds `ansible/requirements.yml` and wires it to the Packer ansible provisioner via its `galaxy_file` option, which runs `ansible-galaxy collection install` automatically before the playbook. Alternative of raw `ansible.builtin.command` ufw calls was rejected: not idempotent, harder to verify in test scenarios.
- **No auto-reboot for unattended-upgrades:** Security patches apply automatically; kernel and reboot-requiring updates are staged but reboots remain a manual operator action. VMs may run a stale kernel until the operator reboots — accepted trade-off to avoid unexpected downtime (see origin).
- **unattended-upgrades configured via Ansible, not user-data:** Ubuntu 24.04 server ships with the package pre-installed. Ansible writes the configuration files, consistent with how the playbook already handles fail2ban, sysctl, and NTP.

---

## Implementation Units

### U1. Expand user-data package list

**Goal:** Replace the current packages block in `user-data` with the full consolidated baseline list agreed in the brainstorm.

**Requirements:** R1

**Dependencies:** none

**Files:**
- `packer/ubuntu-2404/http/user-data` (modify)

**Approach:** Replace the `packages:` block. Full list (alphabetical): `ca-certificates`, `cifs-utils`, `curl`, `dnsutils`, `fail2ban`, `git`, `haveged`, `htop`, `jq`, `logrotate`, `nano`, `ncdu`, `net-tools`, `nfs-common`, `python3`, `python3-passlib`, `python3-pip`, `qemu-guest-agent`, `rsync`, `screen`, `traceroute`, `unzip`, `vim`, `wget`. The existing inline comment explaining `fail2ban` install-vs-configure split should be extended to explain other non-obvious entries (`haveged`, `python3-passlib`, `dnsutils`).

**Patterns to follow:** Existing package entries in `packer/ubuntu-2404/http/user-data` — each entry annotated with a one-line comment when the purpose isn't obvious from the name.

**Test scenarios:**
- Happy path: `packer build` completes end-to-end; all packages install without error during the autoinstall phase.
- Verification: after build, `dpkg -l <package>` confirms installed state for each package.

**Verification:** `packer build` succeeds; `dpkg -l` on the resulting template VM shows all 24 packages installed.

---

### U2. Configure unattended-upgrades

**Goal:** Ensure `unattended-upgrades` applies security-channel patches automatically on running VMs, with auto-reboot explicitly disabled.

**Requirements:** R2, R3

**Dependencies:** none

**Files:**
- `ansible/ubuntu-2404/provision.yml` (modify — add a new task group)

**Approach:** Add a clearly marked task group after the NTP section. Tasks:
1. Ensure `unattended-upgrades` package is present (belt-and-suspenders; it ships with Ubuntu 24.04 server but should be declared explicitly).
2. Write `/etc/apt/apt.conf.d/20auto-upgrades` — enables daily package list refresh and unattended upgrade run.
3. Write `/etc/apt/apt.conf.d/50unattended-upgrades` — configures security-only allowed origin (`${distro_id}:${distro_codename}-security`), `Automatic-Reboot "false"` explicitly set, unused dependency removal enabled. This replaces Ubuntu's default file, which drops ESM/Ubuntu Pro channel configuration — accepted, as these are homelab VMs with no Ubuntu Pro enrollment.

Use `ansible.builtin.apt` for installation and `ansible.builtin.copy` for config files, consistent with the rest of the playbook. No handler needed — unattended-upgrades reads config files on each run; no daemon restart required.

The `Automatic-Reboot "false"` line must be present and explicit. Omitting it leaves the default in place; spelling it out documents the intent clearly in the image.

**Patterns to follow:** `ansible/ubuntu-2404/provision.yml` — section header comment block, `ansible.builtin.copy` with inline `content:`, `mode: '0644'`, comments explaining the WHY for non-obvious settings.

**Test scenarios:**
- Happy path: after Ansible runs, `/etc/apt/apt.conf.d/20auto-upgrades` and `/etc/apt/apt.conf.d/50unattended-upgrades` exist with correct content.
- Behavioral: `unattended-upgrades --dry-run` on a cloned VM exits 0 and reports security updates eligible. Covers AE2.
- Behavioral: `/etc/apt/apt.conf.d/50unattended-upgrades` contains `Automatic-Reboot "false"` — a kernel update does not trigger a reboot. Covers AE2.
- Edge case: running the playbook twice (idempotency) — no changes reported on second run.

**Verification:** Both config files exist with expected content; `unattended-upgrades --dry-run` exits 0; second Ansible run reports no changes.

---

### U3. Add community.general collection infrastructure

**Goal:** Make `community.general` available to the Ansible provisioner at build time so U4's UFW tasks can use the `community.general.ufw` module.

**Requirements:** R5, R6, R7 (prerequisite unit)

**Dependencies:** none

**Files:**
- `ansible/requirements.yml` (create)
- `packer/ubuntu-2404/ubuntu-2404.pkr.hcl` (modify — add `galaxy_file` to the ansible provisioner block)

**Approach:**
- `ansible/requirements.yml`: standard Ansible Galaxy collections file declaring `community.general`. Pin to a compatible minor-version range: `>=12.0.0,<13.0.0`.
- `ubuntu-2404.pkr.hcl`: add `galaxy_file = "${path.root}/../../ansible/requirements.yml"` to the existing `provisioner "ansible"` block. The Packer ansible plugin (>= 1.1.2, as declared) runs `ansible-galaxy collection install -r <galaxy_file>` automatically before the playbook. No CI workflow changes required.

The `galaxy_file` path uses the same `${path.root}/../../` prefix as `playbook_file`, keeping the reference style consistent within the block.

Note: `ansible/requirements.yml` and the `galaxy_file` HCL change must land in the same commit — `packer build` will fail with a collection-not-found error if the HCL references a file that doesn't exist yet.

No CI workflow changes required. The `build` job implicitly relies on `ubuntu-latest` having `ansible` pre-installed (no explicit install step exists). This has been stable, but if builds fail after a runner image update, add an explicit `pip install ansible` step to `.github/workflows/build-template.yml`.

**Patterns to follow:** Existing `provisioner "ansible"` block in `packer/ubuntu-2404/ubuntu-2404.pkr.hcl` — field ordering and comment style.

**Test scenarios:**
- Happy path: `packer validate` passes after the `galaxy_file` line is added (validates HCL syntax and variable resolution; does not install the collection).
- Happy path: `packer build` succeeds — Packer installs the collection, runs the playbook without "module not found" errors.
- Test expectation: none for `ansible/requirements.yml` in isolation — correctness is verified by U4's build succeeding.

**Verification:** `packer validate` exits 0; `packer build` reaches the Ansible provisioner step without collection errors.

---

### U4. Configure UFW baseline firewall

**Goal:** Enable UFW on the template with default-deny incoming and SSH-only allow, so every cloned VM starts with a meaningful firewall posture.

**Requirements:** R5, R6, R7

**Dependencies:** U3

**Files:**
- `ansible/ubuntu-2404/provision.yml` (modify — add a new task group)

**Approach:** Add a task group after the unattended-upgrades section. Tasks:
1. Ensure `ufw` package is present.
2. Set UFW default incoming policy to `deny` using `community.general.ufw`.
3. Allow SSH (port 22/tcp) using `community.general.ufw`.
4. Enable UFW using `community.general.ufw` with `state: enabled`.

Task ordering matters: the SSH allow rule must be in place before UFW is enabled, or the Packer build SSH connection will be severed mid-run. The `community.general.ufw` module with `state: enabled` also accepts a `reset: false` default, which is correct — we do not want to wipe rules on each run.

No handler is needed — `community.general.ufw` applies changes immediately; there is no UFW daemon to reload. Add a comment in the playbook explaining this (contrast with fail2ban which does require a restart).

**Patterns to follow:** Existing task groups in `ansible/ubuntu-2404/provision.yml` — section header comment, `ansible.builtin.apt` for package install, comment explaining the non-obvious (why SSH rule must precede enable, why no handler is registered).

**Test scenarios:**
- Covers AE1: after build, `ufw status verbose` on a cloned VM shows `Status: active`, default incoming `deny`, port 22/tcp `ALLOW`.
- Covers AE1: SSH connection to port 22 of a cloned VM succeeds from the Packer runner.
- Covers AE1: connection attempt to port 80 (or any non-SSH port) on a cloned VM is blocked by UFW.
- Edge case: running the playbook twice — no changes reported (idempotency via `community.general.ufw`).
- Integration: Packer build SSH connection survives UFW enablement — build does not stall at the UFW enable task.

**Verification:** `ufw status verbose` shows expected rules; SSH access works; port probe on non-SSH port is blocked; second Ansible run reports no changes.

---

## Scope Boundaries

- CIS Benchmark compliance and auditd — out of scope.
- Workload-specific firewall ports (k3s, NFS, etc.) — belong in homelab-k8s post-clone playbooks.
- Application-level packages or role-specific configuration — baseline only.
- Additional image variants or other distros.

### Deferred to Follow-Up Work

- UFW IPv6 policy — Ubuntu 24.04's default `/etc/default/ufw` has `IPV6=yes`, so enabling UFW with default-deny incoming applies to both IPv4 and IPv6 without additional rules. No explicit IPv6 rule is added. Verify `IPV6=yes` is intact on a cloned VM during first build test.
- `needrestart` configuration — with unattended-upgrades applying patches, `needrestart` prompts on SSH login could be useful to indicate pending reboots. Deferred to a follow-up hardening pass.

---

## Additional Required Change

**Shell cleanup provisioner — remove Packer build artifacts:** The existing shell cleanup provisioner in `packer/ubuntu-2404/ubuntu-2404.pkr.hcl` (which already handles cloud-init reset, SSH host key removal, and machine-id truncation) must also remove:
1. The Packer build user's sudoers drop-in from `/etc/sudoers.d/` — Packer's ansible provisioner creates a `NOPASSWD:ALL` entry that persists in the template image and is inherited by every cloned VM.
2. Any temporary SSH private keys written to `/tmp` during the ansible provisioner run — Packer normally cleans these up, but explicit removal ensures no key material survives into the template.

---

## Dependencies / Assumptions

- **homelab-k8s dependency:** UFW default-deny means k3s node initialization will fail unless the post-clone Ansible playbook in homelab-k8s opens required cluster ports (6443, 10250, 8472/UDP, etc.) before k3s starts. This repo does not own that playbook; the dependency must be tracked in homelab-k8s. (see origin)
- **community.general `>=12.0.0,<13.0.0`:** Pins to a compatible minor-version range to avoid unexpected breaking changes. When upgrading, bump the upper bound, re-test the UFW tasks, and update this note.
- **Packer ansible plugin galaxy_file support:** The plugin version constraint `>= 1.1.2` covers `galaxy_file`. If `packer init` downloads an older version, raise the floor in the `required_plugins` block.
- **haveged alongside virtio-rng:** Included per operator preference; assumed harmless on QEMU with virtio-rng. (see origin)
