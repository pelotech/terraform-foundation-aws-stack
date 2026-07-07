locals {
  # Built-in per-CNI defaults. `set` entries are merged (defaults first, then
  # var.helm_set) so callers can layer overrides without redefining the base.
  # `timeout` is the per-CNI wait default (overridden by var.wait_timeout).
  cni_defaults = {
    cilium = {
      release_name = "cilium"
      repository   = "https://helm.cilium.io/"
      chart        = "cilium"
      # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
      version       = "1.15.6"
      timeout       = 600
      wait_default  = false # agent bootstraps NotReady nodes; install concurrently
      wait_selector = ""
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
      repository = "oci://ghcr.io/pelotech/charts"
      chart      = "kube-ovn"
      # renovate: datasource=docker depName=ghcr.io/pelotech/charts/kube-ovn
      version       = "v1.13.9"
      timeout       = 900  # 15m
      wait_default  = true # must read node IPs / schedule on the master node first
      wait_selector = "kube-ovn/role=master"
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
      release_name  = try(var.custom_chart.chart, null)
      repository    = try(var.custom_chart.repository, null)
      chart         = try(var.custom_chart.chart, null)
      version       = try(var.custom_chart.version, null)
      timeout       = 600
      wait_default  = false # opt into the poll via wait_for_nodes = true
      wait_selector = ""
      set           = []
    }
  }

  selected = local.cni_defaults[var.cni]
  set      = concat(local.selected.set, var.helm_set)
  timeout  = coalesce(var.wait_timeout, local.selected.timeout)

  wait_for_nodes = var.wait_for_nodes != null ? var.wait_for_nodes : local.selected.wait_default
  node_selector  = var.wait_for_nodes_selector != null ? var.wait_for_nodes_selector : local.selected.wait_selector
}

# Optional gate: wait for nodes to register before installing (kube-ovn needs the
# master node present to read IPs / schedule its control plane). Depends only on
# the cluster inputs, never the node group, so it runs concurrently with node-group
# creation and avoids the managed-node-group readiness deadlock.
resource "terraform_data" "wait_nodes" {
  count = var.create && local.wait_for_nodes ? 1 : 0

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/wait-for-nodes.sh"
    environment = {
      CLUSTER_NAME = var.cluster_name
      REGION       = var.region
      SELECTOR     = local.node_selector
      COUNT        = tostring(var.wait_for_nodes_count)
      TIMEOUT      = tostring(var.wait_for_nodes_timeout)
    }
  }
}

resource "helm_release" "cni" {
  count = var.create ? 1 : 0

  name       = local.selected.release_name
  repository = local.selected.repository
  chart      = local.selected.chart
  version    = coalesce(var.chart_version, local.selected.version)
  namespace  = var.namespace
  timeout    = local.timeout

  # atomic/cleanup_on_fail roll back a failed install so it doesn't leave a
  # pending-install record that blocks the next repair; replace lets a repair
  # reclaim a name whose release is already stuck (failed/pending).
  atomic          = var.atomic
  cleanup_on_fail = var.cleanup_on_fail
  replace         = var.replace

  set    = local.set
  values = var.helm_values

  depends_on = [terraform_data.wait_nodes]
}
