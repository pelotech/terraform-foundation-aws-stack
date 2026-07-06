# Validates per-CNI chart resolution and --set merging without a live cluster.

mock_provider "helm" {}

run "cilium_defaults" {
  command = plan

  variables {
    cni              = "cilium"
    k8s_service_host = "abc123.gr7.us-west-2.eks.amazonaws.com"
  }

  assert {
    condition     = helm_release.cni[0].chart == "cilium" && helm_release.cni[0].version == "1.15.6"
    error_message = "cilium must resolve to the cilium chart at the default version"
  }
  assert {
    condition     = length(terraform_data.wait_nodes) == 0
    error_message = "cilium must install concurrently (no node-registration gate)"
  }
  assert {
    condition     = anytrue([for s in output.resolved_set : s.name == "kubeProxyReplacement" && s.value == "true"])
    error_message = "cilium must enable kubeProxyReplacement by default"
  }
  assert {
    condition     = anytrue([for s in output.resolved_set : s.name == "k8sServiceHost" && s.value == "abc123.gr7.us-west-2.eks.amazonaws.com"])
    error_message = "cilium with kube-proxy replacement must set k8sServiceHost from k8s_service_host"
  }
}

run "cilium_no_kpr_omits_service_host" {
  command = plan

  variables {
    cni                    = "cilium"
    kube_proxy_replacement = false
    k8s_service_host       = "abc123.gr7.us-west-2.eks.amazonaws.com"
  }

  assert {
    condition     = !anytrue([for s in output.resolved_set : s.name == "k8sServiceHost"])
    error_message = "k8sServiceHost must not be set when kube_proxy_replacement is false"
  }
}

run "chart_version_override" {
  command = plan

  variables {
    cni           = "cilium"
    chart_version = "1.16.1"
  }

  assert {
    condition     = output.resolved_version == "1.16.1" && helm_release.cni[0].version == "1.16.1"
    error_message = "chart_version must override the built-in default"
  }
}

run "kube_ovn_defaults" {
  command = plan

  variables {
    cni          = "kube-ovn"
    cluster_name = "test"
    region       = "us-west-2"
  }

  assert {
    condition     = helm_release.cni[0].name == "kube-ovn" && helm_release.cni[0].chart == "kube-ovn" && helm_release.cni[0].repository == "oci://ghcr.io/uki-code/charts" && helm_release.cni[0].version == "v1.13.9"
    error_message = "kube-ovn must resolve to the OCI uki-code kube-ovn chart at v1.13.9"
  }
  assert {
    condition     = helm_release.cni[0].timeout == 900
    error_message = "kube-ovn must default to the 15m (900s) timeout"
  }
  assert {
    condition     = anytrue([for s in output.resolved_set : s.name == "ipv4.SVC_CIDR" && s.value == "10.100.0.0/16"])
    error_message = "kube-ovn must set ipv4.SVC_CIDR from service_cidr (default 10.100.0.0/16)"
  }
  assert {
    condition     = length(terraform_data.wait_nodes) == 1
    error_message = "kube-ovn must gate the install on node registration"
  }
}

run "kube_ovn_service_cidr_override" {
  command = plan

  variables {
    cni          = "kube-ovn"
    cluster_name = "test"
    region       = "us-west-2"
    service_cidr = "172.20.0.0/16"
  }

  assert {
    condition     = anytrue([for s in output.resolved_set : s.name == "ipv4.SVC_CIDR" && s.value == "172.20.0.0/16"])
    error_message = "service_cidr must drive ipv4.SVC_CIDR"
  }
}

run "kube_ovn_empty_service_cidr_omits_set" {
  command = plan

  variables {
    cni          = "kube-ovn"
    cluster_name = "test"
    region       = "us-west-2"
    service_cidr = ""
  }

  assert {
    condition     = !anytrue([for s in output.resolved_set : s.name == "ipv4.SVC_CIDR"])
    error_message = "empty service_cidr must omit the ipv4.SVC_CIDR set value"
  }
}

run "kube_ovn_requires_cluster_name" {
  command = plan

  variables {
    cni    = "kube-ovn"
    region = "us-west-2"
  }

  expect_failures = [var.cluster_name]
}

run "kube_ovn_requires_region" {
  command = plan

  variables {
    cni          = "kube-ovn"
    cluster_name = "test"
  }

  expect_failures = [var.region]
}

run "kube_ovn_wait_disabled" {
  command = plan

  variables {
    cni            = "kube-ovn"
    cluster_name   = "test"
    region         = "us-west-2"
    wait_for_nodes = false
  }

  assert {
    condition     = length(terraform_data.wait_nodes) == 0
    error_message = "wait_for_nodes=false must disable the node-registration gate"
  }
}

run "custom_can_opt_into_poll" {
  command = plan

  variables {
    cni                     = "custom"
    cluster_name            = "test"
    region                  = "us-west-2"
    wait_for_nodes          = true
    wait_for_nodes_selector = "node-role.kubernetes.io/cni=true"
    custom_chart = {
      repository = "https://example.com/charts"
      chart      = "my-cni"
      version    = "0.1.0"
    }
  }

  assert {
    condition     = length(terraform_data.wait_nodes) == 1
    error_message = "a custom CNI must be able to opt into the node-registration gate"
  }
}

run "custom_chart" {
  command = plan

  variables {
    cni = "custom"
    custom_chart = {
      repository = "https://example.com/charts"
      chart      = "my-cni"
      version    = "0.1.0"
    }
  }

  assert {
    condition     = helm_release.cni[0].chart == "my-cni" && helm_release.cni[0].version == "0.1.0" && helm_release.cni[0].repository == "https://example.com/charts"
    error_message = "custom must use the custom_chart coordinates"
  }
}

run "custom_requires_chart" {
  command = plan

  variables {
    cni = "custom"
  }

  expect_failures = [var.custom_chart]
}

run "create_false_installs_nothing" {
  command = plan

  variables {
    create = false
  }

  assert {
    condition     = length(helm_release.cni) == 0
    error_message = "create=false must install no helm release"
  }
}
