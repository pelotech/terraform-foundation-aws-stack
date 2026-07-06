locals {
  # Built-in per-CNI defaults. `set` entries are merged (defaults first, then
  # var.helm_set) so callers can layer overrides without redefining the base.
  # `timeout` is the per-CNI wait default (overridden by var.wait_timeout).
  cni_defaults = {
    cilium = {
      release_name = "cilium"
      repository   = "https://helm.cilium.io/"
      chart        = "cilium"
      version      = "1.15.6"
      timeout      = 600
      set = concat(
        [{ name = "kubeProxyReplacement", value = tostring(var.kube_proxy_replacement) }],
        var.kube_proxy_replacement && var.k8s_service_host != "" ? [
          { name = "k8sServiceHost", value = var.k8s_service_host },
          { name = "k8sServicePort", value = "443" },
        ] : [],
        [
          { name = "hubble.relay.enabled", value = "true" },
          { name = "hubble.ui.enabled", value = "true" },
        ],
      )
    }
    "kube-ovn" = {
      release_name = "kube-ovn"
      # OCI chart. Override via chart_version/helm_set/helm_values. ipv4.SVC_CIDR
      # must match the cluster service CIDR — set from var.service_cidr (wire the
      # foundation eks_cluster_service_cidr output). Pairs with the
      # kube-ovn/role=master node label set by stack_cni="kube-ovn".
      repository = "oci://ghcr.io/uki-code/charts"
      chart      = "kube-ovn"
      version    = "v1.13.9"
      timeout    = 900 # 15m
      set = concat(
        var.service_cidr != "" ? [{ name = "ipv4.SVC_CIDR", value = var.service_cidr }] : [],
        [
          { name = "ipv4.PINGER_EXTERNAL_ADDRESS", value = "8.8.8.8" },
          { name = "ipv4.PINGER_EXTERNAL_DOMAIN", value = "google.com." },
          { name = "func.ENABLE_KEEP_VM_IP", value = "false" },
          { name = "kube-ovn-controller.requests.memory", value = "512Mi" },
          { name = "kube-ovn-controller.limits.memory", value = "512Mi" },
          { name = "ovs-ovn.requests.memory", value = "512Mi" },
          { name = "ovs-ovn.limits.memory", value = "512Mi" },
          { name = "pinger.requests.memory", value = "300Mi" },
          { name = "pinger.limits.memory", value = "300Mi" },
        ],
      )
    }
    custom = {
      release_name = try(var.custom_chart.chart, null)
      repository   = try(var.custom_chart.repository, null)
      chart        = try(var.custom_chart.chart, null)
      version      = try(var.custom_chart.version, null)
      timeout      = 600
      set          = []
    }
  }

  selected = local.cni_defaults[var.cni]
  set      = concat(local.selected.set, var.helm_set)
  timeout  = coalesce(var.wait_timeout, local.selected.timeout)
}

resource "helm_release" "cni" {
  count = var.create ? 1 : 0

  name       = local.selected.release_name
  repository = local.selected.repository
  chart      = local.selected.chart
  version    = coalesce(var.chart_version, local.selected.version)
  namespace  = var.namespace
  timeout    = local.timeout

  set    = local.set
  values = var.helm_values
}