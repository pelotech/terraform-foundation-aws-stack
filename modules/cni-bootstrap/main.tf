locals {
  # Built-in per-CNI defaults. `set` entries are merged (defaults first, then
  # var.helm_set) so callers can layer overrides without redefining the base.
  cni_defaults = {
    cilium = {
      repository = "https://helm.cilium.io/"
      chart      = "cilium"
      version    = "1.15.6"
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
      repository = "https://kubeovn.github.io/kube-ovn/"
      chart      = "kube-ovn"
      # Best-effort default — the kube-ovn chart usually needs value tuning for
      # your topology; override via chart_version/helm_set/helm_values. Pairs
      # with the kube-ovn/role=master node label set by stack_cni="kube-ovn".
      version = "1.13.0"
      set     = []
    }
    custom = {
      repository = try(var.custom_chart.repository, null)
      chart      = try(var.custom_chart.chart, null)
      version    = try(var.custom_chart.version, null)
      set        = []
    }
  }

  selected = local.cni_defaults[var.cni]
  set      = concat(local.selected.set, var.helm_set)
}

resource "helm_release" "cni" {
  count = var.create ? 1 : 0

  name       = local.selected.chart
  repository = local.selected.repository
  chart      = local.selected.chart
  version    = coalesce(var.chart_version, local.selected.version)
  namespace  = var.namespace
  timeout    = var.wait_timeout

  set    = local.set
  values = var.helm_values
}
