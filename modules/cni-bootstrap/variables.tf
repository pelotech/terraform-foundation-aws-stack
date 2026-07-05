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

variable "k8s_service_host" {
  type        = string
  default     = ""
  description = "API server host (no scheme) for Cilium kube-proxy replacement bootstrap. Wire from the foundation module's cilium_k8s_service_host output. Ignored unless cni=cilium and kube_proxy_replacement=true."
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
  default     = 600
  description = "Seconds to wait for the Helm release to become ready."
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
