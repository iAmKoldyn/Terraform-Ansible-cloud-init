output "nodes" {
  description = "All cluster nodes by VM name"
  value       = local.nodes_by_name
}

output "managers" {
  value = local.managers
}

output "workers" {
  value = local.workers
}

output "lbs" {
  value = local.lbs
}
