output "release_name" {
  description = "Name of the installed CNI Helm release (null when create=false)."
  value       = try(helm_release.cni[0].name, null)
}

output "namespace" {
  description = "Namespace the CNI release was installed into."
  value       = var.namespace
}

output "resolved_version" {
  description = "Chart version selected after applying cni defaults and chart_version override."
  value       = coalesce(var.chart_version, local.selected.version)
}

output "resolved_set" {
  description = "Effective Helm --set values (CNI defaults merged with helm_set)."
  value       = local.set
}
