packer {
  required_version = ">= 1.9.0"

  required_plugins {
    vmware = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/vmware"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# Variables
variable "iso_path" {
  type        = string
  description = "Path to RHEL 9.6 installation ISO"
}

variable "iso_checksum" {
  type        = string
  description = "SHA256 checksum of ISO (format: sha256:...)"
  default     = ""
}

variable "version" {
  type        = string
  description = "Build version"
  default     = "1.0.0"
}

variable "vm_name" {
  type        = string
  description = "Name of the virtual machine"
  default     = "rhel9-internal-publisher"
}

variable "cpus" {
  type        = number
  description = "Number of CPUs"
  default     = 2
}

variable "memory" {
  type        = number
  description = "Memory in MB"
  default     = 4096
}

variable "disk_size" {
  type        = number
  description = "Disk size in MB"
  default     = 102400
}

variable "data_disk_size" {
  type        = number
  description = "Data disk size in MB for /data"
  default     = 204800
}

variable "ssh_username" {
  type        = string
  description = "SSH username for provisioning"
  default     = "root"
}

variable "ssh_password" {
  type        = string
  description = "SSH password for provisioning"
  default     = "changeme"
  sensitive   = true
}

variable "headless" {
  type        = bool
  description = "Run build in headless mode"
  default     = true
}

variable "output_directory" {
  type        = string
  description = "Output directory for OVA"
  default     = "output"
}

# Local variables
locals {
  build_timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
  vm_description  = "RHEL 9.6 Internal RPM Repository Publisher - Built ${local.build_timestamp}"
}

# VMware ISO builder
source "vmware-iso" "rhel9-internal" {
  # VM Settings
  vm_name              = var.vm_name
  display_name         = "${var.vm_name}-${var.version}"
  guest_os_type        = "rhel9-64"
  version              = "19"  # VMware HW version 19 (ESXi 7.0 U2+)
  headless             = var.headless
  output_directory     = "${var.output_directory}/${var.vm_name}"

  # Hardware
  cpus                 = var.cpus
  memory               = var.memory
  disk_size            = var.disk_size
  disk_type_id         = "0"  # Thin provisioned
  disk_adapter_type    = "pvscsi"
  network_adapter_type = "vmxnet3"

  # Additional disk for /data
  disk_additional_size = [var.data_disk_size]

  # ISO
  iso_url              = var.iso_path
  iso_checksum         = var.iso_checksum

  # Boot
  boot_wait            = "5s"
  boot_command         = [
    "<up><wait><tab><wait>",
    " inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg",
    "<enter><wait>"
  ]

  # HTTP server for Kickstart
  http_directory       = "http"
  http_port_min        = 8000
  http_port_max        = 8100

  # SSH
  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_timeout          = "30m"
  ssh_handshake_attempts = 100

  # Shutdown
  shutdown_command     = "systemctl poweroff"
  shutdown_timeout     = "10m"

  # VMX customization
  vmx_data = {
    "annotation"                           = local.vm_description
    "tools.syncTime"                       = "TRUE"
    "time.synchronize.continue"            = "TRUE"
    "time.synchronize.restore"             = "TRUE"
    "time.synchronize.resume.disk"         = "TRUE"
    "time.synchronize.shrink"              = "TRUE"
    "time.synchronize.tools.startup"       = "TRUE"
    "isolation.tools.copy.disable"         = "FALSE"
    "isolation.tools.paste.disable"        = "FALSE"
  }

  # Skip compaction for faster builds
  skip_compaction      = false
  skip_export          = false

  # Export to OVA
  format               = "ova"
  ovftool_options      = [
    "--overwrite",
    "--compress=9",
    "--annotation=${local.vm_description}"
  ]
}

# Build definition
build {
  name    = "rhel9-internal-publisher"
  sources = ["source.vmware-iso.rhel9-internal"]

  # Wait for cloud-init or similar to complete
  provisioner "shell" {
    inline = [
      "echo 'Waiting for system to stabilize...'",
      "sleep 30"
    ]
  }

  # Copy provisioning scripts
  provisioner "file" {
    source      = "scripts/"
    destination = "/tmp/packer-scripts/"
  }

  # Copy container image (if pre-built)
  provisioner "file" {
    source      = "../container-image.tar"
    destination = "/tmp/container-image.tar"
    generated   = true
  }

  # Run provisioning script
  provisioner "shell" {
    script           = "scripts/provision.sh"
    environment_vars = [
      "BUILD_VERSION=${var.version}",
      "BUILD_TIMESTAMP=${local.build_timestamp}"
    ]
  }

  # Run hardening script
  provisioner "shell" {
    script           = "scripts/harden.sh"
    environment_vars = [
      "APPLY_STIG=true"
    ]
  }

  # Cleanup
  provisioner "shell" {
    inline = [
      "rm -rf /tmp/packer-scripts/",
      "rm -f /tmp/container-image.tar",
      "dnf clean all",
      "rm -rf /var/cache/dnf/*",
      "rm -f /etc/machine-id",
      "truncate -s 0 /etc/hostname",
      "rm -f /etc/ssh/ssh_host_*",
      "rm -rf /root/.ssh/",
      "rm -f /root/.bash_history",
      "rm -f /home/*/.bash_history",
      "truncate -s 0 /var/log/wtmp",
      "truncate -s 0 /var/log/lastlog",
      "rm -rf /var/log/journal/*",
      "sync"
    ]
  }

  # Post-processor for manifest
  post-processor "manifest" {
    output     = "${var.output_directory}/manifest.json"
    strip_path = true
    custom_data = {
      version   = var.version
      timestamp = local.build_timestamp
      vm_name   = var.vm_name
    }
  }

  # Checksum post-processor
  post-processor "checksum" {
    checksum_types = ["sha256"]
    output         = "${var.output_directory}/{{.BuildName}}.sha256"
  }
}
