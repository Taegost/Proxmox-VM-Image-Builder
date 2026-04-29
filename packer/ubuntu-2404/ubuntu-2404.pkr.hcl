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

variable "proxmox_url"          { type = string }
variable "proxmox_token_id"     { type = string }
variable "proxmox_token_secret" { type = string; sensitive = true }
variable "ssh_public_key"       { type = string }
variable "vm_id"                { type = number; default = 9000 }
variable "node"                 { type = string; default = "proxmox" }

source "proxmox-iso" "ubuntu-2404" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = false  # Set true only if using self-signed certs

  node    = var.node
  vm_id   = var.vm_id
  vm_name = "ubuntu-2404-template"
  template_description = "Ubuntu 24.04 LTS base template - built ${formatdate("YYYY-MM-DD", timestamp())}"

  iso_url      = "https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"
  iso_checksum = "sha256:d6dab0c3a657988501b4bd9b2aeead1f18e27c49f51f41fc226a79cf98bc0c5c"
  iso_storage_pool = "local"
  unmount_iso  = true

  cores   = 2
  memory  = 2048
  os      = "l26"

  scsi_controller = "virtio-scsi-pci"
  disks {
    disk_size    = "20G"
    storage_pool = "local-lvm"
    type         = "scsi"
    format       = "raw"
  }

  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  cloud_init              = true
  cloud_init_storage_pool = "local-lvm"

  http_directory = "http"
  boot_wait      = "5s"
  boot_command = [
    "<esc><wait>",
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ <wait>",
    "<enter><wait>",
    "initrd /casper/initrd<wait>",
    "<enter><wait>",
    "boot<enter>"
  ]

  ssh_username         = "ansible"
  ssh_private_key_file = "~/.ssh/id_ed25519"  # local key for packer connection
  ssh_timeout          = "20m"

  template_name = "ubuntu-2404-template"
}

build {
  sources = ["source.proxmox-iso.ubuntu-2404"]

  provisioner "ansible" {
    playbook_file = "../ansible/provision.yml"
    extra_arguments = ["--extra-vars", "ansible_python_interpreter=/usr/bin/python3"]
  }

  provisioner "shell" {
    inline = [
      # Clean up cloud-init state so it re-runs on first clone boot
      "sudo cloud-init clean",
      "sudo cloud-init clean --logs",
      # Remove SSH host keys (will be regenerated per-clone)
      "sudo rm -f /etc/ssh/ssh_host_*",
      # Remove the machine-id (will be regenerated per-clone)
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      # Clean apt cache
      "sudo apt-get clean",
      "sudo apt-get autoremove -y",
    ]
  }
}