variable "create" {
  type        = bool
  default     = true
  description = "Whether to install the CNI Helm release."
}

variable "cni" {
  type        = string
  default     = "cilium"
  description = "Which CNI to install. One of: cilium, kube-ovn, custom. Use custom with custom_chart to install any Helm-packaged CNI."
  validation {
    condition     = contains(["cilium", "kube-ovn", "custom"], var.cni)
    error_message = "cni must be one of: cilium, kube-ovn, custom."
  }
}

variable "namespace" {
  type        = string
  default     = "kube-system"
  description = "Namespace to install the CNI release into."
}

variable "cluster_name" {
  type        = string
  default     = ""
  description = "EKS cluster name (from the foundation eks_cluster_name output). Required when wait_for_nodes is enabled (kube-ovn default) so the node-registration poll can reach the cluster."
  # NOTE: cluster_name and region repeat this "is waiting effectively on?" check
  # (`wait_for_nodes ?? cni == kube-ovn`). Variable validation can't reference the
  # local that computes it, so the expression is duplicated here and in `region`.
  validation {
    condition     = !(var.wait_for_nodes == null ? var.cni == "kube-ovn" : var.wait_for_nodes) || var.cluster_name != ""
    error_message = "cluster_name is required when waiting for node registration (default for kube-ovn). Wire module.foundation.eks_cluster_name."
  }
}

variable "region" {
  type        = string
  default     = ""
  description = "AWS region of the cluster (from the foundation region output). Required when wait_for_nodes is enabled — the same cluster name can exist in multiple regions, so the poll must region-qualify it."
  validation {
    condition     = !(var.wait_for_nodes == null ? var.cni == "kube-ovn" : var.wait_for_nodes) || var.region != ""
    error_message = "region is required when waiting for node registration (default for kube-ovn). Wire module.foundation.region."
  }
}

variable "k8s_service_host" {
  type        = string
  default     = ""
  description = "API server host (no scheme) for Cilium kube-proxy replacement bootstrap. Wire from the foundation module's cilium_k8s_service_host output. Ignored unless cni=cilium and kube_proxy_replacement=true."
}

variable "service_cidr" {
  type        = string
  default     = ""
  description = "Kubernetes service CIDR for kube-ovn (ipv4.SVC_CIDR). Required for kube-ovn — wire from the foundation module's eks_cluster_service_cidr output so it matches the cluster (a wrong CIDR silently breaks kube-ovn). Ignored for cilium/custom."
  validation {
    condition     = var.cni != "kube-ovn" || var.service_cidr != ""
    error_message = "service_cidr is required for kube-ovn. Wire module.foundation.eks_cluster_service_cidr."
  }
}

variable "kube_proxy_replacement" {
  type        = bool
  default     = true
  description = "Enable Cilium kube-proxy replacement (cni=cilium only). When true, k8sServiceHost/k8sServicePort are set from k8s_service_host."
}

variable "chart_version" {
  type        = string
  default     = null
  description = "Override the CNI Helm chart version. null uses the built-in default for the selected cni (ignored for custom, which uses custom_chart.version)."
}

variable "helm_set" {
  type        = list(object({ name = string, value = string }))
  default     = []
  description = "Extra Helm --set values merged over the CNI defaults (caller entries take effect after the defaults)."
}

variable "helm_values" {
  type        = list(string)
  default     = []
  description = "Extra raw Helm values YAML documents (like -f), applied in order."
}

variable "wait_timeout" {
  type        = number
  default     = null
  description = "Seconds to wait for the Helm release to become ready. null derives per-CNI (cilium/custom 600s, kube-ovn 900s/15m)."
}

variable "atomic" {
  type        = bool
  default     = true
  description = "Roll the release back on a failed install/upgrade (helm --atomic). Prevents a leftover pending-install/failed record that later causes 'cannot re-use a name that is still in use' on a repair. Implies wait."
}

variable "cleanup_on_fail" {
  type        = bool
  default     = true
  description = "Delete new resources created during a failed upgrade (helm --cleanup-on-fail)."
}

variable "replace" {
  type        = bool
  default     = false
  description = "Reuse a release name whose existing release is failed/pending/deleted-in-history (helm install --replace) — lets a repair reclaim a stuck name without a manual `helm uninstall`. Does NOT adopt a healthy deployed release (use `terraform import`). Marked unsafe for production by Helm."
}

variable "bootstrap_generation" {
  type        = string
  default     = ""
  description = "Bump this to force a re-bootstrap: re-runs the node-registration poll and re-applies the CNI helm release against the current nodes. Used during a node recycle/upgrade (e.g. kube-ovn) so the chart re-reads the new master node IPs. Bump it in the RE-ENABLE apply, after the old master node group is destroyed — bumping while the old master is still registered binds the stale node and re-applies the old IP (a no-op). Empty (default) = no forced re-apply."
}

variable "wait_for_nodes" {
  type        = bool
  default     = null
  description = "Poll the cluster and wait for nodes to register before installing (needed by kube-ovn, which reads node IPs). null derives per-CNI (kube-ovn true; cilium/custom false = install concurrently/immediately). Set true for a custom CNI that also needs registered nodes. Requires cluster_name + region."
}

variable "wait_for_nodes_selector" {
  type        = string
  default     = null
  description = "Label selector the node-registration poll waits on. null derives per-CNI (kube-ovn \"kube-ovn/role=master\"; otherwise empty = any node)."
}

variable "wait_for_nodes_count" {
  type        = number
  default     = 1
  description = "Minimum number of registered nodes matching the selector before install proceeds. Default 1 matches the dedicated CNI node group's default size (foundation cni_node_size); set this to your CNI node group's size, or the poll hangs until wait_for_nodes_timeout and fails the apply."
}

variable "wait_for_nodes_timeout" {
  type        = number
  default     = 600
  description = "Seconds the node-registration poll waits before failing."
}

variable "custom_chart" {
  type = object({
    repository = string
    chart      = string
    version    = string
  })
  default     = null
  description = "Chart coordinates for cni=custom. Required when cni=custom, ignored otherwise."
  validation {
    condition     = var.cni != "custom" || var.custom_chart != null
    error_message = "custom_chart is required when cni=custom."
  }
}
