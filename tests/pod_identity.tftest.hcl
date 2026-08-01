# Validates EKS Pod Identity enablement, the per-identity opt-out that keeps an identity on IRSA
# (the GovCloud cross-partition DNS case), cross-account target_role_arn chaining, and Route53
# zone scoping. Uses a mocked AWS provider so no credentials, state, or live cluster are needed.

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
  initial_node = { instance_types = ["m5.large"] }
}

run "default_enables_pod_identity" {
  command = plan

  assert {
    condition     = alltrue(values(output.pod_identity_enabled_resolved))
    error_message = "every identity must use Pod Identity by default"
  }
  assert {
    condition     = output.cluster_addons_enabled_resolved["eks-pod-identity-agent"] == true
    error_message = "the eks-pod-identity-agent addon must be enabled when any identity uses Pod Identity"
  }
  assert {
    condition     = length(output.pod_identity_associations_resolved) == 6
    error_message = "all six identities must resolve an association by default"
  }
  # Namespace/service-account pairs are the contract with the consumer's GitOps layer and must
  # match what the legacy IRSA roles trust, not the upstream chart defaults.
  assert {
    condition = (
      output.pod_identity_associations_resolved["load_balancer_controller"].namespace == "alb" &&
      output.pod_identity_associations_resolved["load_balancer_controller"].service_account == "aws-load-balancer-controller" &&
      output.pod_identity_associations_resolved["ebs_csi_driver"].namespace == "kube-system" &&
      output.pod_identity_associations_resolved["ebs_csi_driver"].service_account == "ebs-csi-driver" &&
      output.pod_identity_associations_resolved["s3_csi_driver"].service_account == "s3-csi-driver" &&
      output.pod_identity_associations_resolved["external_dns"].namespace == "external-dns" &&
      output.pod_identity_associations_resolved["external_dns"].service_account == "external-dns-controller" &&
      output.pod_identity_associations_resolved["cert_manager"].namespace == "cert-manager" &&
      output.pod_identity_associations_resolved["cert_manager"].service_account == "cert-manager" &&
      # Karpenter runs in its own namespace here, NOT the submodule's "kube-system" default.
      output.pod_identity_associations_resolved["karpenter"].namespace == "karpenter" &&
      output.pod_identity_associations_resolved["karpenter"].service_account == "karpenter"
    )
    error_message = "association namespace/service-account pairs must match the pairs the IRSA roles already trust"
  }
  assert {
    condition     = alltrue([for v in values(output.pod_identity_associations_resolved) : v.target_role_arn == null])
    error_message = "no identity may chain to a target role unless one is configured"
  }
}

run "disabled_keeps_irsa_only" {
  command = plan

  variables {
    pod_identity = { enabled = false }
  }

  assert {
    condition     = alltrue([for v in values(output.pod_identity_enabled_resolved) : v == false])
    error_message = "pod_identity.enabled = false must disable every identity"
  }
  assert {
    condition     = length(output.pod_identity_associations_resolved) == 0
    error_message = "no associations may resolve when Pod Identity is disabled"
  }
  assert {
    condition     = output.cluster_addons_enabled_resolved["eks-pod-identity-agent"] == false
    error_message = "the agent addon must be off when no identity uses Pod Identity"
  }
  assert {
    condition     = output.load_balancer_controller_role_arn == null && output.cert_manager_role_arn == null
    error_message = "no Pod Identity roles may be created when Pod Identity is disabled"
  }
}

# GovCloud: hosted zones live in a commercial account, and IAM cannot assume a role across
# partitions. cert-manager and external-dns must fall back to IRSA while everything else migrates.
run "govcloud_dns_opt_out" {
  command = plan

  variables {
    pod_identity = {
      overrides = {
        cert_manager = { enabled = false }
        external_dns = { enabled = false }
      }
    }
  }

  assert {
    condition = (
      output.pod_identity_enabled_resolved["cert_manager"] == false &&
      output.pod_identity_enabled_resolved["external_dns"] == false
    )
    error_message = "the DNS identities must be excluded from Pod Identity when overridden off"
  }
  assert {
    condition = (
      output.pod_identity_enabled_resolved["load_balancer_controller"] == true &&
      output.pod_identity_enabled_resolved["ebs_csi_driver"] == true &&
      output.pod_identity_enabled_resolved["s3_csi_driver"] == true &&
      output.pod_identity_enabled_resolved["karpenter"] == true
    )
    error_message = "opting the DNS identities out must not affect the others"
  }
  assert {
    condition = (
      !contains(keys(output.pod_identity_associations_resolved), "cert_manager") &&
      !contains(keys(output.pod_identity_associations_resolved), "external_dns")
    )
    error_message = "an opted-out identity must not get an association, or Pod Identity would shadow its IRSA annotation"
  }
  assert {
    condition     = output.cert_manager_role_arn == null && output.external_dns_role_arn == null
    error_message = "an opted-out identity must not get a Pod Identity role"
  }
  # The legacy IRSA roles keep serving these two. Not asserted here: their ARNs are unknown at
  # plan time, and the IRSA modules take no input from var.pod_identity, so they cannot regress.
  assert {
    condition     = output.cluster_addons_enabled_resolved["eks-pod-identity-agent"] == true
    error_message = "the agent addon must stay on for the identities that did migrate"
  }
}

run "target_role_arn_sets_chaining" {
  command = plan

  variables {
    pod_identity = {
      overrides = {
        external_dns = { target_role_arn = "arn:aws:iam::210987654321:role/dns-writer" }
      }
    }
  }

  assert {
    condition     = output.pod_identity_associations_resolved["external_dns"].target_role_arn == "arn:aws:iam::210987654321:role/dns-writer"
    error_message = "the association must carry the configured target_role_arn"
  }
  assert {
    condition     = output.pod_identity_associations_resolved["cert_manager"].target_role_arn == null
    error_message = "chaining must not leak to other identities"
  }
  # A chaining identity still needs its own local role to assume from.
  assert {
    condition     = output.pod_identity_enabled_resolved["external_dns"] == true
    error_message = "a chaining identity must stay enabled"
  }
}

run "hosted_zone_arns_scoped" {
  command = plan

  variables {
    pod_identity = {
      overrides = {
        cert_manager = { hosted_zone_arns = ["arn:aws:route53:::hostedzone/Z0001"] }
      }
    }
  }

  assert {
    condition     = join(",", output.pod_identity_hosted_zone_arns_resolved["cert_manager"]) == "arn:aws:route53:::hostedzone/Z0001"
    error_message = "cert_manager must scope to the configured hosted zone"
  }
  # Unset means the historic unscoped grant, not an empty statement.
  assert {
    condition     = join(",", output.pod_identity_hosted_zone_arns_resolved["external_dns"]) == "*"
    error_message = "an unscoped identity must keep the wildcard grant"
  }
}

run "hosted_zone_arns_default_to_wildcard" {
  command = plan

  assert {
    condition = (
      join(",", output.pod_identity_hosted_zone_arns_resolved["cert_manager"]) == "*" &&
      join(",", output.pod_identity_hosted_zone_arns_resolved["external_dns"]) == "*"
    )
    error_message = "hosted zone scoping must default to the historic wildcard grant"
  }
}

# Guards the upstream coalescelist fallback: an empty bucket ARN list would otherwise grant
# s3:ListBucket on arn:aws:s3:::* and emit an object statement with no Resource.
run "s3_policy_skipped_when_no_buckets" {
  command = plan

  variables {
    s3_csi = { create_bucket = false }
  }

  assert {
    condition     = output.s3_csi_policy_attached_resolved == false
    error_message = "the Mountpoint S3 policy must not be attached when there are no bucket ARNs"
  }
}

run "s3_policy_attached_when_bucket_arns_given" {
  command = plan

  variables {
    s3_csi = { create_bucket = false, bucket_arns = ["arn:aws:s3:::example-bucket"] }
  }

  assert {
    condition     = output.s3_csi_policy_attached_resolved == true
    error_message = "the Mountpoint S3 policy must be attached when bucket ARNs are supplied"
  }
}

run "hosted_zone_arns_rejected_on_unsupported_identity" {
  command = plan

  variables {
    pod_identity = {
      overrides = {
        ebs_csi_driver = { hosted_zone_arns = ["arn:aws:route53:::hostedzone/Z0001"] }
      }
    }
  }

  expect_failures = [var.pod_identity]
}

run "empty_hosted_zone_arns_rejected" {
  command = plan

  variables {
    pod_identity = {
      overrides = {
        cert_manager = { hosted_zone_arns = [] }
      }
    }
  }

  expect_failures = [var.pod_identity]
}

run "agent_addon_can_be_forced_off" {
  command = plan

  variables {
    addons = { pod_identity_agent = false }
  }

  assert {
    condition     = output.cluster_addons_enabled_resolved["eks-pod-identity-agent"] == false
    error_message = "an explicit addons.pod_identity_agent = false must win over the derived value"
  }
}

run "create_false_disables_pod_identity" {
  command = plan

  variables {
    create = false
  }

  assert {
    condition     = alltrue([for v in values(output.pod_identity_enabled_resolved) : v == false])
    error_message = "create = false must not resolve any Pod Identity"
  }
  assert {
    condition     = length(output.pod_identity_associations_resolved) == 0
    error_message = "create = false must not resolve any association"
  }
  assert {
    condition     = output.cluster_addons_enabled_resolved["eks-pod-identity-agent"] == false
    error_message = "create = false must not enable the agent addon"
  }
  # Regression guard: these two IRSA roles ignored var.create until v9 and made this whole path
  # unplannable ("provider_arn is null"). They are count-gated now.
  assert {
    condition     = output.load_balancer_controller_role_arn == null && output.ebs_csi_driver_role_arn == null
    error_message = "create = false must not create the ALB or EBS CSI IRSA roles"
  }
}

run "unknown_override_key_rejected" {
  command = plan

  variables {
    pod_identity = {
      overrides = {
        cert_managr = { enabled = false }
      }
    }
  }

  expect_failures = [var.pod_identity]
}

run "target_role_arn_on_disabled_identity_rejected" {
  command = plan

  variables {
    pod_identity = {
      overrides = {
        external_dns = { enabled = false, target_role_arn = "arn:aws:iam::210987654321:role/dns-writer" }
      }
    }
  }

  expect_failures = [var.pod_identity]
}

run "karpenter_chaining_rejected" {
  command = plan

  variables {
    pod_identity = {
      overrides = {
        karpenter = { target_role_arn = "arn:aws:iam::210987654321:role/other" }
      }
    }
  }

  expect_failures = [var.pod_identity]
}
