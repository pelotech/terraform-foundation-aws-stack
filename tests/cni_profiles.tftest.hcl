# Validates that stack_cni drives the initial node group taints/labels and the
# vpc-cni/kube-proxy addon enablement, and that the override escape hatches win.
# Uses a mocked AWS provider so no credentials, state, or live cluster are needed.

mock_provider "aws" {
  # aws_iam_policy_document renders JSON; the auto-generated mock string is not
  # valid JSON and trips downstream IAM role validation. Force a valid object.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
  # The generated partition mock is a random string, which makes IAM ARNs like
  # arn:${partition}:iam::aws:policy/... invalid. Pin it to a real partition.
  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }
  # Callers/session context are fed into aws_iam_session_context, which validates
  # its arn input; the random mock is not a valid ARN.
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:role/test"
      id         = "123456789012"
      user_id    = "AIDATEST"
    }
  }
  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:role/test"
    }
  }
}

variables {
  initial_instance_types = ["m5.large"]
}

run "default_is_cilium" {
  command = plan

  assert {
    condition     = output.initial_node_taints_resolved["cilium"].key == "node.cilium.io/agent-not-ready" && output.initial_node_taints_resolved["cilium"].effect == "NO_EXECUTE"
    error_message = "cilium profile must apply the node.cilium.io/agent-not-ready:NO_EXECUTE taint"
  }
  assert {
    condition     = contains(keys(output.initial_node_taints_resolved), "critical_addons_only")
    error_message = "cilium profile must include the CriticalAddonsOnly taint"
  }
  assert {
    condition     = length(output.initial_node_labels_resolved) == 0
    error_message = "cilium profile must apply no labels by default"
  }
  assert {
    condition     = output.cluster_addons_enabled_resolved["vpc-cni"] == false && output.cluster_addons_enabled_resolved["kube-proxy"] == false && output.cluster_addons_enabled_resolved["coredns"] == true
    error_message = "cilium profile must disable vpc-cni and kube-proxy (kube-proxy replacement) and keep coredns"
  }
}

run "kube_ovn_profile" {
  command = plan

  variables {
    stack_cni = "kube-ovn"
  }

  assert {
    condition     = output.initial_node_taints_resolved["nidhogg"].key == "nidhogg.uswitch.com/kube-system.kube-multus-ds"
    error_message = "kube-ovn profile must apply the nidhogg/multus taint"
  }
  assert {
    condition     = output.initial_node_labels_resolved["kube-ovn/role"] == "master"
    error_message = "kube-ovn profile must label the node kube-ovn/role=master"
  }
  assert {
    condition     = output.cluster_addons_enabled_resolved["vpc-cni"] == false && output.cluster_addons_enabled_resolved["kube-proxy"] == true
    error_message = "kube-ovn profile must disable vpc-cni and keep kube-proxy"
  }
}

run "vpc_cni_profile" {
  command = plan

  variables {
    stack_cni = "vpc-cni"
  }

  assert {
    condition     = length(output.initial_node_taints_resolved) == 1 && contains(keys(output.initial_node_taints_resolved), "critical_addons_only")
    error_message = "vpc-cni profile must apply only the CriticalAddonsOnly taint"
  }
  assert {
    condition     = output.cluster_addons_enabled_resolved["vpc-cni"] == true && output.cluster_addons_enabled_resolved["kube-proxy"] == true
    error_message = "vpc-cni profile must enable vpc-cni and kube-proxy"
  }
}

run "taints_extra_merges_over_preset" {
  command = plan

  variables {
    stack_cni = "cilium"
    initial_node_taints_extra = {
      spot = { key = "spot", value = "true", effect = "NO_SCHEDULE" }
    }
  }

  assert {
    condition     = length(output.initial_node_taints_resolved) == 3 && output.initial_node_taints_resolved["spot"].key == "spot"
    error_message = "initial_node_taints_extra must merge over the cilium preset (critical + cilium + spot)"
  }
}

run "full_override_replaces_preset" {
  command = plan

  variables {
    stack_cni = "cilium"
    initial_node_taints = {
      only = { key = "only", value = "true", effect = "NO_SCHEDULE" }
    }
    # extra is ignored when the full override is set
    initial_node_taints_extra = {
      ignored = { key = "ignored", value = "true", effect = "NO_SCHEDULE" }
    }
  }

  assert {
    condition     = length(output.initial_node_taints_resolved) == 1 && contains(keys(output.initial_node_taints_resolved), "only")
    error_message = "initial_node_taints must fully replace the preset and ignore _extra"
  }
}

run "addon_toggle_override_wins" {
  command = plan

  variables {
    stack_cni                     = "cilium"
    stack_enable_kube_proxy_addon = true
  }

  assert {
    condition     = output.cluster_addons_enabled_resolved["kube-proxy"] == true
    error_message = "explicit stack_enable_kube_proxy_addon must override the cilium-derived default"
  }
}

run "vpc_endpoints_disabled_by_default" {
  command = plan

  assert {
    condition     = length(module.vpc_endpoints) == 0
    error_message = "VPC endpoints must be off by default (vpc_endpoints is empty)"
  }
}

run "vpc_endpoints_enabled_when_listed" {
  command = plan

  variables {
    vpc_endpoints = ["ssm", "ecr.api"]
  }

  assert {
    condition     = length(module.vpc_endpoints) == 1
    error_message = "a non-empty vpc_endpoints must create the vpc_endpoints module"
  }
}

run "vpc_endpoints_s3_only" {
  command = plan

  variables {
    vpc_endpoints = ["s3"]
  }

  assert {
    condition     = length(module.vpc_endpoints) == 1 && length(module.vpc_endpoints[0].endpoints) == 1 && contains(keys(module.vpc_endpoints[0].endpoints), "s3")
    error_message = "listing only s3 must create just the S3 (gateway) endpoint and nothing else"
  }
}
