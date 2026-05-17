# =============================================================================
# Packer build definition — Ubuntu 24.04 LTS template for Proxmox
#
# What this produces:
#   A Proxmox VM template (ID 9000 by default) that can be cloned to create
#   new VMs. The template is minimal, hardened, and cloud-init enabled.
#   It is NOT a running VM — it is a golden image.
#
# How to run locally:
#   cd packer/ubuntu-2404
#   export PKR_VAR_proxmox_url="https://eschaton:8006/api2/json"
#   export PKR_VAR_proxmox_token_id="packer@pve!packer-token"
#   export PKR_VAR_proxmox_token_secret="<uuid>"
#   export PKR_VAR_ssh_public_key="ssh-ed25519 AAAA..."
#   export PKR_VAR_ssh_private_key_file="~/.ssh/ansible_ed25519"
#   export PKR_VAR_ansible_password_hash='$6$...'
#   packer init .
#   packer build -on-error=cleanup .
#
# -on-error=cleanup is important: without it, a failed build leaves an orphan
# VM in Proxmox that must be manually destroyed before the next run succeeds.
#
# Variable values: see variables.pkr.hcl for full descriptions and debugging tips.
# =============================================================================

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.8"
      source  = "github.com/hashicorp/proxmox"
    }
    ansible = {
      version = ">= 1.1.2"
      source  = "github.com/hashicorp/ansible"
    }
  }
}


# =============================================================================
# Source: Proxmox ISO
# =============================================================================

source "proxmox-iso" "ubuntu-2404" {

  # --- Proxmox connection ---
  proxmox_url  = var.proxmox_url
  username     = var.proxmox_token_id
  token        = var.proxmox_token_secret

  # Homelab Proxmox nodes almost always use self-signed certificates.
  # Set to false only if your Proxmox host has a valid CA-signed cert (e.g., via ACME).
  # With false and a self-signed cert, packer will fail with a TLS verification error.
  insecure_skip_tls_verify = true

  node = var.proxmox_node

  # --- Template identity ---
  vm_id   = var.vm_id
  vm_name = "ubuntu-2404-template"

  # The description is visible in the Proxmox UI. Embedding the build date here
  # means you can tell at a glance how old the template is — useful when
  # troubleshooting cloned VMs at 2am and wondering if they have recent patches.
  template_description = "Ubuntu 24.04 LTS baseline template. Built by Packer on ${formatdate("YYYY-MM-DD", timestamp())}. Do not modify manually — rebuild via the pipeline."

  # --- Ubuntu ISO ---
  # The Proxmox HOST downloads this ISO directly. The machine running Packer
  # does not need to download it. If the build stalls at 'Retrieving ISO',
  # the Proxmox node cannot reach releases.ubuntu.com — check DNS and firewall.
  #
  # When Ubuntu releases a new point release (e.g., 24.04.3), update BOTH
  # iso_url AND iso_checksum together. A mismatched checksum fails immediately
  # with a clear error; a stale URL fails with a 404 or redirected content.
  # Latest checksums: https://releases.ubuntu.com/24.04/SHA256SUMS
  iso_url          = "https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"
  iso_checksum     = "sha256:d6dab0c3a657988501b4bd9b2aeead1f18e27c49f51f41fc226a79cf98bc0c5c"
  iso_storage_pool = var.iso_storage_pool

  # Unmount the installation ISO after the build so cloned VMs don't try to
  # boot from it on first power-on instead of their own disk.
  unmount_iso = true

  # --- Cloud-init seed ISO (user-data injection) ---
  #
  # We deliver the autoinstall user-data via a small ISO uploaded to Proxmox
  # storage rather than via Packer's built-in HTTP server. Here is why:
  #
  # Packer's HTTP server approach requires the VM being built to make an HTTP
  # request back to the machine running Packer (the GitHub Actions runner).
  # In our setup, the runner reaches Proxmox via Tailscale, but the VM being
  # built is a brand-new machine with no Tailscale client — so there is no
  # network path from the build VM to the runner. The HTTP approach cannot work.
  #
  # The CIDATA ISO approach avoids this entirely: Packer generates a small ISO
  # from the user-data file, uploads it to Proxmox storage via the API (which
  # does work over Tailscale), and mounts it as a CD-ROM. The VM reads its
  # cloud-init config from the local CD without any network calls.
  #
  # The ISO is labeled CIDATA so Ubuntu's cloud-init NoCloud datasource detects
  # it automatically — no kernel cmdline arguments needed to point at a URL.
  #
  # templatefile() renders user-data before creating the ISO, which is how we
  # inject the SSH public key. This is not possible with the HTTP approach
  # (which serves files statically with no substitution).
  additional_iso_files {
    cd_content = {
      "user-data" = templatefile("${path.root}/http/user-data", {
        ssh_public_key        = var.ssh_public_key
        ansible_password_hash = var.ansible_password_hash
      })
      # meta-data is required by the NoCloud spec but can be empty.
      # cloud-init generates its own instance-id when the file is blank.
      "meta-data" = ""
    }
    cd_label = "CIDATA"

    # ide2 is used for the seed ISO; ide0 is reserved for the Ubuntu install ISO.
    # If the build VM has trouble finding user-data, verify this device is visible
    # in the Proxmox UI hardware tab during the build.
    device           = "ide2"
    iso_storage_pool = var.iso_storage_pool
  }

  # --- Hardware ---
  # These settings apply to the template. VMs cloned from the template can
  # override CPU/RAM at clone time — these are starting-point defaults.
  os     = "l26"   # QEMU OS type for Linux 2.6+ kernel; affects QEMU CPU/timer optimizations
  cores  = 2
  memory = 2048    # MB — enough to run the installer and Ansible; resize clones as needed

  # virtio-scsi-pci gives the best disk I/O performance for Linux guests.
  # The disk type below must be 'scsi' to attach to this controller type.
  # Do not change to 'ide' or 'sata' without a deliberate performance trade-off.
  scsi_controller = "virtio-scsi-pci"

  disks {
    type         = "scsi"
    disk_size    = "20G"
    storage_pool = var.disk_storage_pool
    format       = "raw"

    # discard=true enables TRIM support. When the guest deletes files, the
    # underlying LVM thin pool reclaims the space. Without this, deleted guest
    # data consumes LVM space indefinitely and your storage pool fills up.
    discard = true
  }

  network_adapters {
    model  = "virtio"  # Best throughput for Linux; requires virtio drivers (built into Ubuntu kernel)
    bridge = "vmbr0"   # Default Proxmox LAN bridge. Change if your network uses a different bridge name.

    # firewall=false disables the Proxmox software firewall on this NIC.
    # The OS-level hardening (sysctl, fail2ban) is the security layer here.
    firewall = false
  }

  # --- Proxmox cloud-init drive ---
  # This is SEPARATE from the CIDATA seed ISO above. This drive stays in the
  # template permanently. When you clone the template, Proxmox uses this drive
  # to inject per-clone config (hostname, static IP, SSH key) based on what
  # you fill in on the Cloud-Init tab in the Proxmox UI or via API/Terraform.
  cloud_init              = true
  cloud_init_storage_pool = var.cloud_init_storage_pool

  # --- Boot command ---
  # Packer types this into the VM's virtual console immediately after the
  # machine boots from the Ubuntu ISO. We drop into the GRUB command line
  # and boot the installer kernel manually.
  #
  # Why manual kernel boot instead of editing the GRUB menu entry?
  # The GRUB menu layout can change between Ubuntu point releases, making
  # menu-edit boot commands fragile. Booting from the GRUB command line
  # (c) is stable across releases.
  #
  # 'autoinstall' tells Ubuntu's subiquity installer to run unattended.
  # Without this keyword, the installer waits for user input even if a
  # valid user-data file is present.
  #
  # The '---' separates kernel arguments from the casper (live system) arguments.
  #
  # Debugging tip: if autoinstall doesn't start, remove 'quiet' to see
  # full installer output in the Proxmox VM console. If user-data is not
  # found, verify the CIDATA ISO is mounted and labeled correctly.
  boot_wait = "5s"
  boot_command = [
    "<esc><wait>",
    "c<wait>",
    "linux /casper/vmlinuz autoinstall quiet ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  # --- SSH connection for Packer provisioners ---
  # After the OS installs and reboots, Packer waits for SSH to become available,
  # then runs the Ansible and shell provisioners over this connection.
  # This is NOT the same as post-clone Ansible access — it is only alive
  # for the duration of the Packer build.
  #
  # Timeout at 'Waiting for SSH'? Most likely causes (in order):
  #   1. Key mismatch: ssh_public_key and ssh_private_key_file are not a pair
  #   2. Autoinstall did not complete: check the VM console in Proxmox
  #   3. VM network did not come up: cloud-init may have failed to configure ens18
  ssh_username         = "ansible"
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "20m"
}


# =============================================================================
# Build
# =============================================================================

build {
  name    = "ubuntu-2404"
  sources = ["source.proxmox-iso.ubuntu-2404"]

  # --- Ansible: baseline provisioning ---
  # Runs after the OS is installed and SSH is available.
  # Scope: baseline security hardening only.
  # Do NOT add application-specific tasks here — this playbook runs for every
  # VM cloned from this template regardless of its eventual purpose.
  # Application config lives in post-clone Ansible inventories.
  provisioner "ansible" {
    playbook_file = "${path.root}/../../ansible/ubuntu-2404/provision.yml"
    galaxy_file   = "${path.root}/../../ansible/requirements.yml"
    user          = "ansible"
    extra_arguments = [
      "--extra-vars", "ansible_python_interpreter=/usr/bin/python3",
      "--extra-vars", "iac_service_ssh_public_key=${var.iac_service_ssh_public_key}",
      # Increase verbosity for debugging Ansible connectivity issues:
      # "-vvv",
    ]
  }

  # --- Shell: final cleanup before template conversion ---
  # Runs AFTER Ansible. Prepares the disk image so that each cloned VM boots
  # cleanly with its own identity. Order within this block matters.
  provisioner "shell" {
    inline = [
      # Reset cloud-init state so it runs fresh on each clone's first boot.
      # Without this, cloud-init sees its 'already ran' marker and skips
      # hostname/IP/SSH key injection — every clone gets the template's identity.
      # --logs clears /var/log/cloud-init* so the clone's logs start clean.
      "sudo cloud-init clean --logs",

      # Remove SSH host keys so each clone generates its own unique set on first boot.
      # Skipping this means every clone has identical host keys — a security risk,
      # and every SSH client will show 'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED'
      # the first time it connects to a freshly cloned VM.
      "sudo rm -f /etc/ssh/ssh_host_*",

      # Truncate (not delete) machine-id so systemd regenerates it on first boot.
      # Identical machine-ids cause DHCP lease collisions — multiple clones will
      # fight over the same IP address and you will have mysterious network failures.
      # Truncating preserves the bind-mount that some systemd versions expect;
      # deleting the file entirely can cause boot warnings.
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",

      # Remove the Packer build user's sudoers entry.
      # The ansible user needs NOPASSWD:ALL during the build (set in user-data),
      # but iac-service is the post-clone automation account and owns sudoers going forward.
      # Leaving this entry in the template would give every cloned VM an extra
      # privileged account whose sole purpose ended at image build time.
      "sudo rm -f /etc/sudoers.d/ansible",

      # Remove any temporary SSH key material from /tmp.
      # Belt-and-suspenders: the Packer ansible provisioner may write ephemeral
      # key files to /tmp during the build session.
      "sudo find /tmp -maxdepth 1 -name '*.key' -delete 2>/dev/null || true",

      # Shrink the template's disk footprint.
      "sudo apt-get clean",
      "sudo apt-get autoremove -y",
    ]
  }
}
