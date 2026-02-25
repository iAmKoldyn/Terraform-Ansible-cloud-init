locals {
  max_host_number = floor(pow(2, 32 - var.cluster_prefix_length)) - 2

  manager_ip_end = var.manager_ip_start + var.managers_count - 1
  worker_ip_end  = var.worker_ip_start + var.workers_count - 1
  lb_ip_end      = var.lb_ip_start + var.lbs_count - 1

  cidr_prefix_match = can(tonumber(split("/", var.cluster_cidr)[1])) && tonumber(split("/", var.cluster_cidr)[1]) == var.cluster_prefix_length

  ip_ranges_fit_subnet = (
    local.max_host_number >= 2 &&
    (var.managers_count == 0 || (var.manager_ip_start >= 2 && local.manager_ip_end <= local.max_host_number)) &&
    (var.workers_count == 0 || (var.worker_ip_start >= 2 && local.worker_ip_end <= local.max_host_number)) &&
    (var.lbs_count == 0 || (var.lb_ip_start >= 2 && local.lb_ip_end <= local.max_host_number))
  )

  ip_ranges_non_overlapping = (
    (var.managers_count == 0 || var.workers_count == 0 || local.manager_ip_end < var.worker_ip_start || local.worker_ip_end < var.manager_ip_start) &&
    (var.managers_count == 0 || var.lbs_count == 0 || local.manager_ip_end < var.lb_ip_start || local.lb_ip_end < var.manager_ip_start) &&
    (var.workers_count == 0 || var.lbs_count == 0 || local.worker_ip_end < var.lb_ip_start || local.lb_ip_end < var.worker_ip_start)
  )

  managers = [for i in range(var.managers_count) : {
    name      = format("%s-manager-%02d", var.vm_name_prefix, i + 1)
    role      = "manager"
    ip        = cidrhost(var.cluster_cidr, var.manager_ip_start + i)
    cpus      = var.manager_cpus
    memory_mb = var.manager_memory_mb
  }]

  workers = [for i in range(var.workers_count) : {
    name      = format("%s-worker-%02d", var.vm_name_prefix, i + 1)
    role      = "worker"
    ip        = cidrhost(var.cluster_cidr, var.worker_ip_start + i)
    cpus      = var.worker_cpus
    memory_mb = var.worker_memory_mb
  }]

  lbs = [for i in range(var.lbs_count) : {
    name      = format("%s-lb-%02d", var.vm_name_prefix, i + 1)
    role      = "lb"
    ip        = cidrhost(var.cluster_cidr, var.lb_ip_start + i)
    cpus      = var.lb_cpus
    memory_mb = var.lb_memory_mb
  }]

  nodes         = concat(local.managers, local.workers, local.lbs)
  nodes_by_name = { for n in local.nodes : n.name => n }
}

resource "null_resource" "seed_iso" {
  for_each = local.nodes_by_name

  lifecycle {
    precondition {
      condition     = local.cidr_prefix_match
      error_message = "cluster_prefix_length must match prefix from cluster_cidr."
    }
    precondition {
      condition     = local.ip_ranges_fit_subnet
      error_message = "Node IP ranges must stay within usable host range of cluster_cidr."
    }
    precondition {
      condition     = local.ip_ranges_non_overlapping
      error_message = "Manager/worker/lb IP ranges overlap. Use non-overlapping host ranges."
    }
  }

  triggers = {
    node_name             = each.value.name
    node_ip               = each.value.ip
    cluster_prefix_length = tostring(var.cluster_prefix_length)
    hostonly_guest_if     = var.hostonly_guest_interface
    nat_guest_if          = var.nat_guest_interface
    ssh_public_key_path   = var.ssh_public_key_path
    bootstrap_revision    = var.bootstrap_revision
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      $script = Resolve-Path "${path.module}/../scripts/new-seed-iso.ps1"
      $rootPath = (Resolve-Path "${path.module}/..").Path
      $isoPath = Join-Path $rootPath "cloud-init/build/${each.value.name}/seed.iso"
      & $script -NodeName "${each.value.name}" -NodeIp "${each.value.ip}" -PrefixLength ${var.cluster_prefix_length} -HostOnlyInterface "${var.hostonly_guest_interface}" -NatInterface "${var.nat_guest_interface}" -SshPublicKeyPath "${var.ssh_public_key_path}" -OutputIso $isoPath
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["PowerShell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      $rootPath = (Resolve-Path "${path.module}/..").Path
      $dir = Join-Path $rootPath "cloud-init/build/${self.triggers.node_name}"
      if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    EOT
  }
}

resource "null_resource" "vm" {
  for_each   = local.nodes_by_name
  depends_on = [null_resource.seed_iso]

  triggers = {
    vm_name           = each.value.name
    vm_role           = each.value.role
    vm_ip             = each.value.ip
    cpus              = tostring(each.value.cpus)
    memory_mb         = tostring(each.value.memory_mb)
    template_vm_name  = var.template_vm_name
    host_only_adapter = var.host_only_adapter
    start_vms         = tostring(var.start_vms)
    bootstrap_rev     = var.bootstrap_revision
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      $rootPath = (Resolve-Path "${path.module}/..").Path
      $script = Join-Path $rootPath "scripts/new-vm.ps1"
      $seedIso = Join-Path $rootPath "cloud-init/build/${each.value.name}/seed.iso"
      & $script -TemplateName "${var.template_vm_name}" -VmName "${each.value.name}" -HostOnlyAdapter "${var.host_only_adapter}" -Cpus ${each.value.cpus} -MemoryMb ${each.value.memory_mb} -SeedIsoPath $seedIso -StartVm ${var.start_vms ? 1 : 0}
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["PowerShell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      $script = Resolve-Path "${path.module}/../scripts/remove-vm.ps1"
      & $script -VmName "${self.triggers.vm_name}"
    EOT
  }
}
