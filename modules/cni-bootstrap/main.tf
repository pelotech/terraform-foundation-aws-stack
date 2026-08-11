locals {
  # Built-in per-CNI defaults. `set` entries are merged (defaults first, then
  # var.helm_set) so callers can layer overrides without redefining the base;
  # kube-ovn defaults render from values/<cni>.yaml.tftpl (--set still wins).
  # `timeout` is the per-CNI wait default (overridden by var.wait_timeout).
  cni_defaults = {
    cilium = {
      release_name = "cilium"
      repository   = "https://helm.cilium.io/"
      chart        = "cilium"
      # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
      version       = "1.19.6"
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
      # Legacy v1 chart (env-style values). Pairs with the kube-ovn/role=master
      # node label set by stack_cni="kube-ovn".
      repository = "oci://ghcr.io/pelotech/charts"
      chart      = "kube-ovn"
      # renovate: datasource=docker depName=ghcr.io/pelotech/charts/kube-ovn
      version       = "v1.13.9"
      timeout       = 900  # 15m
      wait_default  = true # must read node IPs / schedule on the master node first
      wait_selector = "kube-ovn/role=master"
      set           = []
    }
    "kube-ovn-v2" = {
      # Upstream v2 chart (structured values). Same release name as v1 so a
      # release installed via cni="custom" upgrades in place when switching.
      release_name = "kube-ovn"
      repository   = "oci://ghcr.io/kubeovn/charts"
      chart        = "kube-ovn-v2"
      # renovate: datasource=docker depName=ghcr.io/kubeovn/charts/kube-ovn-v2
      version       = "v1.16.2"
      timeout       = 900  # 15m
      wait_default  = true # must read node IPs / schedule on the master node first
      wait_selector = "kube-ovn/role=master"
      set           = []
    }
    custom = {
      # Release name is decoupled from the chart name: optional release_name wins,
      # chart is the fallback. try() covers custom_chart = null (cni != custom).
      release_name  = try(coalesce(var.custom_chart.release_name, var.custom_chart.chart), null)
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

  wait_for_nodes = var.wait_for_nodes != null ? var.wait_for_nodes : local.selected.wait_default
  node_selector  = var.wait_for_nodes_selector != null ? var.wait_for_nodes_selector : local.selected.wait_selector

  # kube-ovn pins its control plane to the master-labeled nodes — driven from the
  # same selector the register-poll uses. v1 takes the raw string; v2 needs a
  # key/value pair, so a non key=value selector yields "" and the v2 template
  # falls back to the chart defaults.
  master_label_parts = split("=", local.node_selector)
  master_label_key   = length(local.master_label_parts) == 2 ? local.master_label_parts[0] : ""
  master_label_value = length(local.master_label_parts) == 2 ? local.master_label_parts[1] : ""

  # Default values documents (like -f), applied before var.helm_values so
  # caller documents win.
  cni_values = {
    cilium = []
    "kube-ovn" = [templatefile("${path.module}/values/kube-ovn.yaml.tftpl", {
      service_cidr       = var.service_cidr
      master_nodes_label = local.node_selector
    })]
    "kube-ovn-v2" = [templatefile("${path.module}/values/kube-ovn-v2.yaml.tftpl", {
      service_cidr       = var.service_cidr
      master_label_key   = local.master_label_key
      master_label_value = local.master_label_value
    })]
    custom = []
  }

  # Inert value that changes with bootstrap_generation so a bump forces `helm upgrade`
  # (re-reads the current master node IPs after a recycle). Charts ignore unknown keys.
  # NOTE: this only recycles the master correctly when there is a single matching node.
  # kube-ovn re-reads the IP of whatever node the poll binds, so bump this during the
  # RE-ENABLE apply (after the old master node group is destroyed) — bumping it while the
  # old master is still registered binds the stale node and re-applies the old IP (no-op).
  generation_set = var.bootstrap_generation != "" ? [{ name = "cniBootstrapGeneration", value = var.bootstrap_generation }] : []

  set     = concat(local.selected.set, local.generation_set, var.helm_set)
  values  = concat(local.cni_values[var.cni], var.helm_values)
  timeout = coalesce(var.wait_timeout, local.selected.timeout)
}

# Optional gate: wait for nodes to register before installing (kube-ovn needs the
# master node present to read IPs / schedule its control plane). Depends only on
# the cluster inputs, never the node group, so it runs concurrently with node-group
# creation and avoids the managed-node-group readiness deadlock.
resource "terraform_data" "wait_nodes" {
  count = var.create && local.wait_for_nodes ? 1 : 0

  # Re-run the poll (and, via the helm generation_set, the CNI reapply) when the
  # operator bumps bootstrap_generation during a node recycle/upgrade. Reliable only
  # when the old master is already gone (see generation_set note): with the old node
  # still present the poll can bind it instead of the freshly-recycled master.
  triggers_replace = [var.bootstrap_generation]

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
  count      = var.create ? 1 : 0
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
  values = local.values

  depends_on = [terraform_data.wait_nodes]
}
