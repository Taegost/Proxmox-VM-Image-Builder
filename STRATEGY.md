---
name: Proxmox VM Image Builder
last_updated: 2026-05-17
---

# Proxmox VM Image Builder Strategy

## Target problem

A homelab operator has no repeatable process for building Proxmox VM base images — every rebuild is manual, error-prone, and produces inconsistent results. There is no standard way to restore or expand the lab without carrying forward whatever was done by hand last time.

## Our approach

Treat VM image builds as software: version-controlled Packer + Ansible definitions, validated by CI on every change. The pipeline is the documentation — every build is reproducible and the process cannot silently drift.

## Who it's for

**Primary:** Homelab operator expanding their Proxmox setup — they're hiring Proxmox VM Image Builder to get a known-good, consistently-built baseline template so new workloads start clean without inheriting manual drift.

## Key metrics

- **Build time** — median CI build duration; measured in GitHub Actions logs (leading, moves weekly)
- **Template freshness** — days since last successful image publish; measured from CI artifacts
- **Manual steps eliminated** — count of setup steps still requiring human action outside the pipeline; tracked by inspection
- **Drift incidents** — times a deployed VM diverged from expected template state; tracked by observation

## Tracks

### Supported images

Define and maintain a small, curated set of Proxmox VM templates — one per distinct base OS or role needed in the lab.

_Why it serves the approach:_ The templates are the deliverable; keeping the set small and well-maintained matters more than coverage breadth.

### Pipeline reliability

Keep CI green, builds fast, and the automated process trustworthy end-to-end.

_Why it serves the approach:_ A pipeline that fails silently or inconsistently defeats the entire bet on code-defined images.

### Hardening baseline

Maintain a consistent security and configuration baseline baked into all images via Ansible.

_Why it serves the approach:_ Baseline hardening is what makes cloned VMs trustworthy by default, not just reproducible.

## Not working on

- VM provisioning and cloning (handled by Terraform or `qm clone` post-template)
- Application-level configuration (workload-specific setup belongs in `homelab-k8s`)
