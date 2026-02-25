variable "template_vm_name" {
  description = "Name of the VirtualBox golden template VM"
  type        = string
  default     = "ubuntu-22.04-docker-template"
}

variable "host_only_adapter" {
  description = "VirtualBox host-only adapter name"
  type        = string
  validation {
    condition     = length(trimspace(var.host_only_adapter)) > 0
    error_message = "host_only_adapter must be a non-empty adapter name."
  }
}

variable "vm_name_prefix" {
  description = "Prefix used for all cluster VMs"
  type        = string
  default     = "kp"
}

variable "cluster_cidr" {
  description = "CIDR used for static host-only IP assignment"
  type        = string
  validation {
    condition     = can(cidrhost(var.cluster_cidr, 1))
    error_message = "cluster_cidr must be a valid IPv4 CIDR (for example 192.168.56.0/24)."
  }
}

variable "cluster_prefix_length" {
  description = "Prefix length for static host-only IP"
  type        = number
  validation {
    condition     = var.cluster_prefix_length >= 16 && var.cluster_prefix_length <= 29
    error_message = "cluster_prefix_length must be in range 16..29."
  }
}

variable "manager_ip_start" {
  description = "Host part start for managers"
  type        = number
  validation {
    condition     = var.manager_ip_start >= 2
    error_message = "manager_ip_start must be >= 2."
  }
}

variable "worker_ip_start" {
  description = "Host part start for workers"
  type        = number
  validation {
    condition     = var.worker_ip_start >= 2
    error_message = "worker_ip_start must be >= 2."
  }
}

variable "lb_ip_start" {
  description = "Host part start for load balancers"
  type        = number
  validation {
    condition     = var.lb_ip_start >= 2
    error_message = "lb_ip_start must be >= 2."
  }
}

variable "hostonly_guest_interface" {
  description = "Guest OS interface name connected to host-only network"
  type        = string
  default     = "enp0s3"
  validation {
    condition     = length(trimspace(var.hostonly_guest_interface)) > 0
    error_message = "hostonly_guest_interface must be a non-empty interface name."
  }
}

variable "nat_guest_interface" {
  description = "Guest OS interface name connected to NAT network"
  type        = string
  default     = "enp0s8"
  validation {
    condition     = length(trimspace(var.nat_guest_interface)) > 0 && var.nat_guest_interface != var.hostonly_guest_interface
    error_message = "nat_guest_interface must be non-empty and different from hostonly_guest_interface."
  }
}

variable "managers_count" {
  description = "Number of swarm managers"
  type        = number
  default     = 3
}

variable "workers_count" {
  description = "Number of swarm workers"
  type        = number
  default     = 2
}

variable "lbs_count" {
  description = "Number of HAProxy/Keepalived nodes"
  type        = number
  default     = 2
}

variable "manager_cpus" {
  type    = number
  default = 2
}

variable "manager_memory_mb" {
  type    = number
  default = 3072
}

variable "worker_cpus" {
  type    = number
  default = 2
}

variable "worker_memory_mb" {
  type    = number
  default = 2048
}

variable "lb_cpus" {
  type    = number
  default = 1
}

variable "lb_memory_mb" {
  type    = number
  default = 1536
}

variable "ssh_public_key_path" {
  description = "Public key path. Supports Windows path or WSL path (/mnt/c/...)"
  type        = string
  default     = "/mnt/c/Users/YOUR_WINDOWS_USER/.ssh/id_ed25519.pub"
}

variable "bootstrap_revision" {
  description = "Bump this value to force regeneration of seed ISOs and VM reprovision"
  type        = string
  default     = "v1"
}

variable "start_vms" {
  description = "Start VMs automatically after provisioning"
  type        = bool
  default     = true
}
