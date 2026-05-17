# =============================================================================
# Variable declarations for the Ubuntu 24.04 Packer build
#
# Rules:
#   - All variables live here, never in ubuntu-2404.pkr.hcl
#   - Sensitive variables are marked sensitive = true and never logged
#   - Every variable answers "what breaks if this is wrong?"
#   - Defaults exist only where a sensible homelab-wide value is known
#
# Setting values:
#   CI:    GitHub Actions secrets → PKR_VAR_* env vars (see workflow)
#   Local: export PKR_VAR_proxmox_url="https://..." before running packer build
#   Never: commit a .pkrvars.hcl file — it is in .gitignore for a reason
# =============================================================================


# =============================================================================
# Proxmox Connection
# =============================================================================

variable "proxmox_url" {
  type        = string
  description = "Full Proxmox API URL including the /api2/json path. Example: https://eschaton:8006/api2/json"
  # Common mistakes that cause 'connection refused' or 401 errors:
  #   - Using /api2/extjs instead of /api2/json
  #   - Omitting the port (8006 is the default)
  #   - Using an IP when Proxmox's TLS cert is issued to the hostname (or vice versa)
}

variable "proxmox_token_id" {
  type        = string
  description = "Packer API token ID. Format: <user>@<realm>!<token-name>  Example: packer@pve!packer-token"
  # This is the token identifier, not the secret. Treat with care regardless —
  # it narrows the attack surface if the secret ever leaks.
}

variable "proxmox_token_secret" {
  type        = string
  sensitive   = true
  description = "API token secret UUID. Shown once at creation time in Proxmox UI under Datacenter > Permissions > API Tokens."
  # If auth fails with a valid token_id, the secret was likely regenerated in the UI.
  # Re-create it and update the PROXMOX_TOKEN_SECRET GitHub secret to match.
}


# =============================================================================
# Build Target
# =============================================================================

variable "proxmox_node" {
  type        = string
  default     = "eschaton"
  description = "Proxmox node name where the VM is built. Must match exactly as shown in the Proxmox UI sidebar (case-sensitive)."
  # 'node not found' errors mean this doesn't match. Check the name in the UI —
  # it appears under 'Datacenter' in the left panel.
}

variable "vm_id" {
  type        = number
  default     = 9000
  description = "Proxmox VM ID for the template. IDs 9000-9999 are reserved for Packer-built templates in this homelab. Ubuntu 24.04 = 9000."
  # 'VM ID already in use' means the old template was not cleaned up.
  # Destroy it first: qm destroy 9000  (run on the Proxmox node or use the UI)
  # IDs must be unique cluster-wide, not just per-node.
}


# =============================================================================
# Storage
# =============================================================================

variable "iso_storage_pool" {
  type        = string
  default     = "local"
  description = "Proxmox storage pool where the Ubuntu ISO is downloaded and cached. The Proxmox HOST fetches the ISO — not the machine running Packer."
  # 'local' is node-local directory storage. Fine for single-node setups.
  # For clusters, use shared storage so any node can access the cached ISO.
  # Build stalls at 'waiting for ISO'? The Proxmox node can't reach releases.ubuntu.com.
}

variable "disk_storage_pool" {
  type        = string
  default     = "local-lvm"
  description = "Storage pool for the VM root disk during the build. This becomes the template disk that clones inherit."
}

variable "cloud_init_storage_pool" {
  type        = string
  default     = "local-lvm"
  description = "Storage pool for the cloud-init drive Proxmox attaches to cloned VMs. Must support the raw disk format."
  # local-lvm works on Proxmox 7.x and newer.
  # If you see errors about cloud-init drive creation, change this to 'local'
  # (directory-based storage that supports all formats).
}


# =============================================================================
# SSH / Ansible Access
# =============================================================================

variable "ssh_public_key" {
  type        = string
  sensitive   = true
  description = "Ed25519 public key authorized for the ansible user. Baked into the template's authorized_keys. Used by Packer during the build AND by Ansible on every VM cloned from this template."
  # This key is permanent — it lives in every VM cloned from this template forever.
  # The matching private key must be available wherever post-clone Ansible runs.
  #
  # Packer timeout at 'waiting for SSH'? Most likely causes:
  #   1. This is the PUBLIC key but it doesn't match the PRIVATE key in ssh_private_key_file
  #   2. The autoinstall didn't complete — open the VM console in Proxmox to check
  #   3. The VM's network interface came up on a different name than ens18 (check user-data)
}

variable "ssh_private_key_file" {
  type        = string
  default     = "~/.ssh/ansible_ed25519"
  description = "Filesystem path to the private key matching ssh_public_key. Used only by Packer during the build to run the Ansible provisioner. Never uploaded or stored by Packer."
  # In CI: the workflow writes the SSH_PRIVATE_KEY secret to /tmp/packer_ansible_key
  #        and passes PKR_VAR_ssh_private_key_file=/tmp/packer_ansible_key
  # Locally: point this at your actual private key file.
  # packer validate does not attempt SSH, so this file does not need to exist for validation.
}

variable "ansible_password_hash" {
  type        = string
  sensitive   = true
  description = "SHA-512 crypt hash of the ansible user's Linux password. Required by cloud-init autoinstall to create the user. SSH password auth is disabled — this password is only usable at the local Proxmox console."
  # Even though remote SSH with a password is disabled, this password CAN be used
  # for local console login and sudo — so don't use something trivial.
  #
  # Generate a hash (run this locally, never commit the output):
  #   openssl passwd -6 -salt $(openssl rand -hex 8) 'YourPasswordHere'
  #
  # The result starts with $6$ (SHA-512 crypt). Store the full string as
  # the ANSIBLE_PASSWORD_HASH GitHub Actions secret.
}

variable "iac_service_ssh_public_key" {
  type        = string
  sensitive   = true
  description = "Ed25519 public key authorized for the iac-service account. Baked into /home/iac-service/.ssh/authorized_keys by Ansible during the build. iac-service is the post-clone automation account; it replaces the ansible user for ongoing management after the template is built."
  # Store the full 'ssh-ed25519 AAAA... comment' string as the
  # IAC_SERVICE_SSH_PUBLIC_KEY GitHub Actions secret.
  # The matching private key is what post-clone Ansible playbooks use to connect.
}
