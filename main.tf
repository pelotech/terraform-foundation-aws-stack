data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  permissions_boundary_arn = var.permissions_boundary != "" ? "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.permissions_boundary}" : null
  is_arm                   = can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", var.pelotech_nat.instance_type))
  # Graviton names carry a "g" (m7g/c6gd/t4g); the a1 family is not detected. Arch agreement across
  # instance_types is validated, so index [0] is representative.
  initial_is_arm = can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", var.initial_node.instance_types[0]))

  # WARNING: the generated keys ("admin_0", "admin_ro_0", ...) are POSITIONAL state addresses.
  # Removing or reordering an ARN mid-list re-keys every entry after it, which destroys and
  # recreates those access entries. Append only. A duplicate ARN across groups also collides
  # server-side (EKS keys access entries by principal ARN) and fails with ResourceInUseException.
  access_entry_groups = {
    admin    = { arns = var.access.admin_arns, assoc_key = "cluster_admin", policy = "AmazonEKSClusterAdminPolicy" }
    admin_ro = { arns = var.access.admin_ro_arns, assoc_key = "admin_view_only", policy = "AmazonEKSAdminViewPolicy" }
    ro       = { arns = var.access.ro_arns, assoc_key = "view_only", policy = "AmazonEKSViewPolicy" }
  }
  managed_access_entries = merge([
    for group, cfg in local.access_entry_groups : {
      for index, arn in cfg.arns : "${group}_${index}" => {
        principal_arn = arn
        policy_associations = {
          (cfg.assoc_key) = {
            policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/${cfg.policy}"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    }
  ]...)
  extra_access_entries = {
    for index, item in var.extra_access_entries : "extra_${index}" => item
  }
  s3_csi_arns = compact(concat([module.s3_csi.s3_bucket_arn], var.s3_csi.bucket_arns))

  # WARNING: deliberately NOT the upstream chart defaults (kube-system:ebs-csi-driver, not
  # ebs-csi-controller-sa; alb, not kube-system). These pairs must match what the IRSA roles already
  # trust and what the GitOps layer deploys, or the association silently serves nothing.
  workload_identities = {
    load_balancer_controller = { namespace = "alb", service_account = "aws-load-balancer-controller" }
    ebs_csi_driver           = { namespace = "kube-system", service_account = "ebs-csi-driver" }
    s3_csi_driver            = { namespace = "kube-system", service_account = "s3-csi-driver" }
    external_dns             = { namespace = "external-dns", service_account = "external-dns-controller" }
    cert_manager             = { namespace = "cert-manager", service_account = "cert-manager" }
    karpenter                = { namespace = "karpenter", service_account = "karpenter" }
  }

  # The two mechanisms resolve identically and independently, so an identity can stay on IRSA while
  # the rest of the cluster moves to Pod Identity — needed on Fargate, where the agent cannot run.
  irsa_enabled = {
    for k in keys(local.workload_identities) : k =>
    var.create && coalesce(try(var.irsa.overrides[k].enabled, null), var.irsa.enabled)
  }

  pod_identity_enabled = {
    for k in keys(local.workload_identities) : k =>
    var.create && coalesce(try(var.pod_identity.overrides[k].enabled, null), var.pod_identity.enabled)
  }

  # Follows usage rather than a flag, because every IRSA role interpolates the provider ARN.
  irsa_oidc_provider_enabled = var.create && coalesce(
    var.irsa.create_oidc_provider,
    anytrue(values(local.irsa_enabled)),
  )

  pod_identity_target_role_arns = {
    for k in keys(local.workload_identities) : k =>
    local.pod_identity_enabled[k] ? try(var.pod_identity.overrides[k].target_role_arn, null) : null
  }

  # Unset keeps the historic unscoped grant.
  pod_identity_hosted_zone_arns = {
    for k in ["cert_manager", "external_dns"] : k =>
    try(var.pod_identity.overrides[k].hosted_zone_arns, null) != null ? var.pod_identity.overrides[k].hosted_zone_arns : ["*"]
  }

  # Derived from the inputs, not s3_csi_arns: the created bucket's ARN is unknown at plan time and
  # this gates a count. An empty list would emit an empty-Resource statement, so skip the policy.
  attach_s3_csi_policy = var.s3_csi.create_bucket || length(var.s3_csi.bucket_arns) > 0

  # OVERWRITE adopts pre-existing self-managed daemonsets; preserve=false overrides the upstream
  # default so disabling an addon also removes its workload, required for clean CNI swaps.
  cluster_addon_defaults = {
    "vpc-cni" = {
      most_recent                 = true
      before_compute              = true
      preserve                    = false
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    "kube-proxy" = {
      most_recent                 = true
      preserve                    = false
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    # tolerations REPLACES the addon's defaults rather than appending, so only set it when the
    # profile needs something beyond stock (which already tolerates CriticalAddonsOnly).
    "coredns" = merge({
      most_recent                 = true
      preserve                    = false
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      }, length(local.coredns_tolerations) > 0 ? {
      configuration_values = jsonencode({ tolerations = local.coredns_tolerations })
    } : {})
    # before_compute is a head start, not a graph edge: it skips the depends_on [node groups] the
    # regular addon resource carries. Without it the agent is created last, after every node group,
    # while the associations are created before them — so a node-group failure leaves associations
    # with no agent and nothing pointing at the cause.
    "eks-pod-identity-agent" = {
      most_recent                 = true
      before_compute              = true
      preserve                    = false
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }
  # cni_node is null unless the CNI needs a dedicated control-plane group. coredns_tolerations is
  # only what coredns must tolerate BEYOND the addon's defaults — keep it minimal, since a
  # toleration coredns does not need lets it schedule somewhere the design assumes it will not.
  cni_profiles = {
    cilium = {
      system_node = {
        taints = {
          critical_addons_only = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
          cilium               = { key = "node.cilium.io/agent-not-ready", value = "true", effect = "NO_EXECUTE" }
        }
        labels = {}
      }
      cni_node = null
      # cilium-operator removes agent-not-ready once ready, so the taint gates coredns only until
      # the CNI is usable. CriticalAddonsOnly is already stock.
      coredns_tolerations     = []
      enable_vpc_cni_addon    = false
      enable_kube_proxy_addon = false # cilium kube-proxy replacement
    }
    "kube-ovn" = {
      system_node = {
        taints = {
          critical_addons_only = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
          nidhogg_kube_ovn     = { key = "nidhogg.uswitch.com/kube-system.kube-ovn-pinger", value = "true", effect = "NO_SCHEDULE" }
          nidhogg_multus       = { key = "nidhogg.uswitch.com/kube-system.kube-multus-ds", value = "true", effect = "NO_SCHEDULE" }
        }
        labels = {}
      }
      cni_node = {
        taints = {
          kube_ovn_control_plane = { key = "kube-ovn.io/control-plane", value = "true", effect = "NO_SCHEDULE" }
        }
        labels = { "kube-ovn/role" = "master" }
      }
      # The nidhogg gates only; without them coredns deadlocks behind the multus/pinger DaemonSets.
      #
      # WARNING: do NOT add kube-ovn.io/control-plane. The CNI node group is destroyed and recreated
      # on every recycle, and the runbook promises DNS survives because coredns is not on it.
      # Tolerating that taint lets coredns land there — it is the emptiest node right after a
      # recycle, exactly what the scheduler prefers — taking DNS down alongside ovn-central.
      coredns_tolerations = [
        { key = "nidhogg.uswitch.com/kube-system.kube-ovn-pinger", operator = "Exists" },
        { key = "nidhogg.uswitch.com/kube-system.kube-multus-ds", operator = "Exists" },
      ]
      enable_vpc_cni_addon    = false
      enable_kube_proxy_addon = true
    }
    "vpc-cni" = {
      system_node = {
        taints = {
          critical_addons_only = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
        }
        labels = {}
      }
      cni_node                = null
      coredns_tolerations     = []
      enable_vpc_cni_addon    = true
      enable_kube_proxy_addon = true
    }
  }
  cni_profile = local.cni_profiles[var.cni]

  # Full-override var wins entirely (null = derive); otherwise preset + _extra merge.
  initial_taints = var.initial_node.taints != null ? var.initial_node.taints : merge(local.cni_profile.system_node.taints, var.initial_node.taints_extra)
  initial_labels = var.initial_node.labels != null ? var.initial_node.labels : merge(local.cni_profile.system_node.labels, var.initial_node.labels_extra)

  enable_cni_node_group   = local.cni_profile.cni_node != null && coalesce(var.cni_node.enabled, true)
  cni_node_taints         = try(local.cni_profile.cni_node.taints, {})
  cni_node_labels         = try(local.cni_profile.cni_node.labels, {})
  coredns_tolerations     = local.cni_profile.coredns_tolerations
  cni_node_instance_types = coalesce(var.cni_node.instance_types, var.initial_node.instance_types)
  cni_node_is_arm         = can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", local.cni_node_instance_types[0]))

  node_group_common = {
    iam_role_use_name_prefix       = false
    iam_role_permissions_boundary  = local.permissions_boundary_arn
    capacity_type                  = "ON_DEMAND"
    enable_monitoring              = true
    use_latest_ami_release_version = false
    metadata_options = {
      http_endpoint               = "enabled"
      http_put_response_hop_limit = 2
      http_tokens                 = "required"
    }
    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size           = 100
          volume_type           = "gp3"
          encrypted             = true
          delete_on_termination = true
        }
      }
    }
    cloudinit_pre_nodeadm        = local.enable_vpc_cni_addon ? [] : local.cloudinit_pre_nodeadm
    pre_bootstrap_user_data      = var.pre_bootstrap_user_data
    iam_role_additional_policies = var.node_iam_additional_policies
    timeouts                     = var.initial_node.timeouts
  }

  # Explicit bool wins; null derives from the CNI profile / Pod Identity usage.
  enable_vpc_cni_addon      = var.addons.vpc_cni != null ? var.addons.vpc_cni : local.cni_profile.enable_vpc_cni_addon
  enable_kube_proxy_addon   = var.addons.kube_proxy != null ? var.addons.kube_proxy : local.cni_profile.enable_kube_proxy_addon
  enable_pod_identity_agent = var.addons.pod_identity_agent != null ? var.addons.pod_identity_agent : anytrue(values(local.pod_identity_enabled))

  cluster_addons_enabled = {
    "vpc-cni"                = local.enable_vpc_cni_addon
    "kube-proxy"             = local.enable_kube_proxy_addon
    "coredns"                = var.addons.coredns
    "eks-pod-identity-agent" = local.enable_pod_identity_agent
  }
  cluster_addons = {
    for name, enabled in local.cluster_addons_enabled : name =>
    merge(local.cluster_addon_defaults[name], try(var.addons.overrides[name], {}))
    if enabled
  }

  # See https://awslabs.github.io/amazon-eks-ami/nodeadm/doc/api/
  cloudinit_pre_nodeadm = [
    {
      content_type = "application/node.eks.aws"
      content      = <<-EOT
            ---
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              kubelet:
                config:
                  maxPods: 110
          EOT
    }
  ]
}

module "vpc" {
  source                                 = "terraform-aws-modules/vpc/aws"
  version                                = "6.6.1"
  name                                   = var.name
  create_vpc                             = var.existing_vpc == null
  enable_dns_hostnames                   = "true"
  enable_dns_support                     = "true"
  enable_nat_gateway                     = var.pelotech_nat.enabled != true
  one_nat_gateway_per_az                 = var.pelotech_nat.enabled != true
  cidr                                   = var.vpc.cidr
  azs                                    = var.vpc.azs
  private_subnets                        = var.vpc.private_subnets
  public_subnets                         = var.vpc.public_subnets
  database_subnets                       = var.vpc.database_subnets
  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "karpenter.sh/discovery"          = var.name
    "kubernetes.io/role/internal-elb" = 1
  }
  tags = var.tags
}

locals {
  nat_tailscale_enabled       = var.pelotech_nat.enabled && var.pelotech_nat.tailscale.enabled
  nat_tailscale_create_ssm    = local.nat_tailscale_enabled && var.pelotech_nat_tailscale_auth_key != ""
  nat_tailscale_auth_key_ssm  = var.pelotech_nat.tailscale.auth_key_ssm != "" ? var.pelotech_nat.tailscale.auth_key_ssm : "/${var.name}/nat/tailscale-auth-key"
  nat_tailscale_hostname_base = var.pelotech_nat.tailscale.hostname != "" ? var.pelotech_nat.tailscale.hostname : var.name

  nat_tailscale_conf_by_az = local.nat_tailscale_enabled ? {
    for az in module.vpc.azs : az => compact([
      "tailscale_enabled=\"true\"",
      "tailscale_auth_key_ssm=\"${local.nat_tailscale_auth_key_ssm}\"",
      var.pelotech_nat.tailscale.advertise_routes != "" ? "tailscale_advertise_routes=\"${var.pelotech_nat.tailscale.advertise_routes}\"" : "",
      var.pelotech_nat.tailscale.exit_node ? "tailscale_exit_node=\"true\"" : "",
      "tailscale_hostname=\"${local.nat_tailscale_hostname_base}-${az}\"",
      var.pelotech_nat.tailscale.snat_subnet_routes ? "" : "tailscale_snat_subnet_routes=\"false\"",
      var.pelotech_nat.tailscale.extra_args != "" ? "tailscale_extra_args=\"${var.pelotech_nat.tailscale.extra_args}\"" : "",
    ])
  } : {}

  # Appended after fck-nat's own user_data part. Quoted heredoc so nothing expands at boot.
  nat_tailscale_cloud_init_by_az = {
    for az, lines in local.nat_tailscale_conf_by_az : az => {
      content_type = "text/x-shellscript"
      content = join("\n", concat(
        ["#!/bin/sh", "set -eu", "cat >>/etc/fck-nat.conf <<'EOC'"],
        lines,
        ["EOC", "service fck-nat restart", ""],
      ))
    }
  }
}

resource "aws_ssm_parameter" "nat_tailscale_auth_key" {
  count = local.nat_tailscale_create_ssm ? 1 : 0
  name  = local.nat_tailscale_auth_key_ssm
  type  = "SecureString"
  value = var.pelotech_nat_tailscale_auth_key
  tags  = var.tags
}

resource "aws_iam_role_policy" "nat_tailscale_ssm" {
  count = local.nat_tailscale_enabled ? length(module.vpc.azs) : 0
  name  = "${var.name}-nat-tailscale-ssm"
  role  = module.fck_nat[count.index].role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${trimprefix(local.nat_tailscale_auth_key_ssm, "/")}"
    }]
  })
}

data "aws_ami" "main" {
  count       = var.pelotech_nat.enabled ? 1 : 0
  most_recent = true
  owners      = [var.pelotech_nat.ami_owner_id]
  filter {
    name   = "name"
    values = [var.pelotech_nat.ami_name_filter]
  }

  filter {
    name   = "architecture"
    values = [local.is_arm ? "arm64" : "x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_eip" "main" {
  count = (var.pelotech_nat.enabled || var.pelotech_nat.create_eip) ? length(module.vpc.azs) : 0
  tags = merge(var.tags, {
    Name = "nat-${var.name}-${count.index}"
  })
}

module "fck_nat" {
  # Temporary fork carrying RaJiska/terraform-aws-fck-nat#84 (partition-aware IAM ARNs) for GovCloud.
  #
  # REVERT TRIGGER: #84 merged 2026-08-01; waiting on a release. When an upstream tag >= v1.6.1
  # exists, restore source = "RaJiska/fck-nat/aws" and delete this fork. Renovate cannot see a git::
  # source with a non-semver tag, so nothing will nag us automatically.
  source             = "git::https://github.com/josmo/terraform-aws-fck-nat.git?ref=v1.6.1-pre-josmo"
  count              = var.pelotech_nat.enabled ? length(module.vpc.azs) : 0
  eip_allocation_ids = [aws_eip.main[count.index].allocation_id]
  name               = "${var.name}-${module.vpc.azs[count.index]}"
  ami_id             = data.aws_ami.main[0].id
  vpc_id             = module.vpc.vpc_id
  subnet_id          = module.vpc.public_subnets[count.index]
  # TODO: look to enable agent/spot
  # use_cloudwatch_agent = true
  # use_spot_instances   = true
  instance_type       = var.pelotech_nat.instance_type
  auto_rollout        = var.pelotech_nat.auto_rollout
  cloud_init_parts    = local.nat_tailscale_enabled ? [local.nat_tailscale_cloud_init_by_az[module.vpc.azs[count.index]]] : []
  update_route_tables = true
  route_tables_ids = {
    private = module.vpc.private_route_table_ids[count.index]
  }
  tags = merge(var.tags, {
    Name = "${var.name}-${module.vpc.azs[count.index]}"
  })
}

data "aws_region" "current" {}

# Lets nodes reach ECR/STS/SSM/EC2 without NAT egress. Internal (module-created) VPC only.
# https://docs.aws.amazon.com/govcloud-us/latest/UserGuide/using-govcloud-vpc-endpoints.html
module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "6.6.1"
  count   = var.existing_vpc == null && length(var.vpc_endpoints) > 0 ? 1 : 0

  vpc_id = module.vpc.vpc_id

  create_security_group      = true
  security_group_name_prefix = "${var.name}-vpce-"
  security_group_rules = {
    https_from_vpc = {
      type        = "ingress"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }

  # s3/dynamodb are free Gateway endpoints; everything else is a paid Interface endpoint.
  endpoints = merge(
    {
      for s in var.vpc_endpoints : replace(s, ".", "_") => {
        service         = s
        service_type    = "Gateway"
        route_table_ids = module.vpc.private_route_table_ids
      } if contains(["s3", "dynamodb"], s)
    },
    {
      for s in var.vpc_endpoints : replace(s, ".", "_") => {
        service             = s
        private_dns_enabled = true
        subnet_ids          = module.vpc.private_subnets
      } if !contains(["s3", "dynamodb"], s)
    },
  )

  tags = var.tags
}

module "eks" {
  source                        = "terraform-aws-modules/eks/aws"
  version                       = "21.24.2"
  name                          = var.name
  kubernetes_version            = var.cluster_version
  create                        = var.create
  create_node_security_group    = var.create_node_security_group
  iam_role_permissions_boundary = local.permissions_boundary_arn
  endpoint_private_access       = true
  endpoint_public_access        = var.cluster_endpoint_public_access
  enabled_log_types             = var.cluster_enabled_log_types
  vpc_id                        = var.existing_vpc != null ? var.existing_vpc.vpc_id : module.vpc.vpc_id
  subnet_ids                    = var.existing_vpc != null ? var.existing_vpc.subnet_ids : module.vpc.private_subnets
  addons                        = local.cluster_addons
  create_kms_key                = var.create_cluster_kms
  # Also gates the cluster's IAM OIDC provider, so disabling nulls eks_oidc_provider_arn.
  enable_irsa = local.irsa_oidc_provider_enabled
  encryption_config = var.create_cluster_kms ? {
    "resources" : [
      "secrets"
    ]
  } : {}
  kms_key_administrators = var.create_cluster_kms ? concat(var.access.admin_arns, var.access.admin_ro_arns) : []
  eks_managed_node_groups = merge(
    # Follows the control-plane version and rolls in place on upgrade.
    var.initial_node.enabled ? {
      "initial-${var.name}" = merge(local.node_group_common, {
        instance_types = var.initial_node.instance_types
        min_size       = var.initial_node.min_size
        max_size       = var.initial_node.max_size
        desired_size   = var.initial_node.desired_size
        ami_type       = local.initial_is_arm ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"
        labels         = local.initial_labels
        taints         = local.initial_taints
        # Only set when true so the upstream module's default stays in charge otherwise.
      }, var.initial_node.force_update_version ? { force_update_version = true } : {})
    } : {},
    # Version-pinned and recycled (destroy/recreate) on upgrade, so the initial group is untouched.
    local.enable_cni_node_group ? {
      "cni-${var.name}" = merge(local.node_group_common, {
        instance_types      = local.cni_node_instance_types
        min_size            = var.cni_node.size
        max_size            = var.cni_node.size
        desired_size        = var.cni_node.size
        kubernetes_version  = coalesce(var.cni_node.kubernetes_version, var.cluster_version)
        ami_release_version = var.cni_node.ami_release_version
        ami_type            = local.cni_node_is_arm ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"
        labels              = local.cni_node_labels
        taints              = local.cni_node_taints
      })
    } : {},
  )
  access_entries = merge(local.managed_access_entries, local.extra_access_entries)
  tags = merge(var.tags, {
    # At most one security group per account may carry this tag.
    "karpenter.sh/discovery" = var.name
  })
}

# Bolts web-identity onto Karpenter's role, which already trusts pods.eks.amazonaws.com upstream.
data "aws_iam_policy_document" "source" {
  # Folds in var.create: oidc_provider and oidc_provider_arn are null when not created, and
  # interpolating either here fails at plan time.
  count = local.irsa_enabled["karpenter"] ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      values   = ["sts.amazonaws.com"]
      variable = "${module.eks.oidc_provider}:aud"
    }
    condition {
      test     = "StringEquals"
      values   = ["system:serviceaccount:karpenter:karpenter"]
      variable = "${module.eks.oidc_provider}:sub"
    }
    principals {
      identifiers = [module.eks.oidc_provider_arn]
      type        = "Federated"
    }
  }
}
module "karpenter" {
  count                           = var.create ? 1 : 0
  source                          = "terraform-aws-modules/eks/aws//modules/karpenter"
  version                         = "21.24.2"
  enable_inline_policy            = true
  cluster_name                    = module.eks.cluster_name
  queue_name                      = var.name
  node_iam_role_name              = "KarpenterNodeRole-${var.name}"
  iam_role_name                   = "${var.name}-karpenter-role"
  iam_role_use_name_prefix        = false
  node_iam_role_use_name_prefix   = false
  create_pod_identity_association = local.pod_identity_enabled["karpenter"]
  # WARNING: must be set explicitly. The submodule defaults to namespace "kube-system"; taking that
  # default associates a service account that does not exist and silently strands Karpenter.
  namespace                          = local.workload_identities["karpenter"].namespace
  service_account                    = local.workload_identities["karpenter"].service_account
  iam_role_permissions_boundary_arn  = local.permissions_boundary_arn
  node_iam_role_permissions_boundary = local.permissions_boundary_arn
  # Keyed off IRSA, not Pod Identity, so this role can hold the web-identity trust and the
  # association at once — the same dual-mode window the two-role identities get.
  iam_role_source_assume_policy_documents = local.irsa_enabled["karpenter"] ? data.aws_iam_policy_document.source[*].json : []
  tags                                    = var.tags
}

module "load_balancer_controller_irsa_role" {
  count   = local.irsa_enabled["load_balancer_controller"] ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.1"

  use_name_prefix = false
  name            = "${var.name}-alb-role"
  policy_name     = "AmazonEKS_AWS_Load_Balancer_Controller-${var.name}"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    cluster = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["alb:aws-load-balancer-controller"]
    }
  }
  permissions_boundary = local.permissions_boundary_arn
  tags                 = var.tags
}

module "ebs_csi_driver_irsa_role" {
  count   = local.irsa_enabled["ebs_csi_driver"] ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.1"

  use_name_prefix = false
  name            = "${var.name}-ebs-csi-driver-role"
  policy_name     = "AmazonEKS_EBS_CSI_Policy-${var.name}"

  attach_ebs_csi_policy = true

  oidc_providers = {
    cluster = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-driver"]
    }
  }
  permissions_boundary = local.permissions_boundary_arn
  tags                 = var.tags
}

module "s3_csi" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.15.4"
  # var.s3_csi validates that bucket_name is set or tags has an Owner key, so this cannot crash.
  bucket = coalesce(var.s3_csi.bucket_name, "${try(var.tags.Owner, "")}-${var.name}-csi-bucket")

  create_bucket                         = var.s3_csi.create_bucket
  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true
  block_public_acls                     = true
  block_public_policy                   = true
  ignore_public_acls                    = true
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }
  tags = var.tags
}

module "s3_driver_irsa_role" {
  count   = local.irsa_enabled["s3_csi_driver"] ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.1"

  use_name_prefix = false
  name            = "${var.name}-s3-csi-driver-role"
  policy_name     = "AmazonEKS_Mountpoint_S3_CSI-${var.name}"

  attach_mountpoint_s3_csi_policy = local.attach_s3_csi_policy
  mountpoint_s3_csi_bucket_arns   = local.s3_csi_arns
  mountpoint_s3_csi_path_arns     = [for arn in local.s3_csi_arns : "${arn}/*"]
  oidc_providers = {
    cluster = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:s3-csi-driver"]
    }
  }
  permissions_boundary = local.permissions_boundary_arn
  tags                 = var.tags
}

module "external_dns_irsa_role" {
  count   = local.irsa_enabled["external_dns"] ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.1"

  use_name_prefix = false
  name            = "${var.name}-external-dns-role"
  policy_name     = "AmazonEKS_External_DNS_Policy-${var.name}"

  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["*"]

  oidc_providers = {
    cluster = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns-controller"]
    }
  }
  permissions_boundary = local.permissions_boundary_arn
  tags                 = var.tags
}


module "cert_manager_irsa_role" {
  count   = local.irsa_enabled["cert_manager"] ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.1"

  use_name_prefix = false
  name            = "${var.name}-cert-manager-role"
  policy_name     = "AmazonEKS_Cert_Manager_Policy-${var.name}"

  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = ["*"]

  oidc_providers = {
    cluster = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }
  permissions_boundary = local.permissions_boundary_arn
  tags                 = var.tags
}

################################################################################
# Pod Identity roles and associations
#
# These live alongside the IRSA roles rather than replacing them, so the ARNs differ — audit any
# external resource policy naming the old one.
#
# WARNING: the input names differ from the IRSA module's. This one uses `permissions_boundary_arn`,
# `attach_aws_lb_controller_policy`, `attach_aws_ebs_csi_policy`,
# `mountpoint_s3_csi_bucket_path_arns`, and exports `iam_role_arn` (not `arn`).
################################################################################

# The target role carries the permissions, so the predefined policy is suppressed for this grant.
# Same-partition only, which is why GovCloud falls back to IRSA for commercial-account Route53.
data "aws_iam_policy_document" "pod_identity_target_role" {
  for_each = { for k, v in local.pod_identity_target_role_arns : k => v if v != null }

  statement {
    sid       = "AssumeTargetRole"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = [each.value]
  }
}

module "load_balancer_controller_pod_identity" {
  count   = local.pod_identity_enabled["load_balancer_controller"] ? 1 : 0
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.8.2"

  use_name_prefix               = false
  name                          = "${var.name}-alb-pod-identity-role"
  aws_lb_controller_policy_name = "AmazonEKS_AWS_Load_Balancer_Controller_PodIdentity-${var.name}"

  attach_aws_lb_controller_policy = local.pod_identity_target_role_arns["load_balancer_controller"] == null
  attach_custom_policy            = local.pod_identity_target_role_arns["load_balancer_controller"] != null
  source_policy_documents         = try([data.aws_iam_policy_document.pod_identity_target_role["load_balancer_controller"].json], [])

  associations = {
    cluster = {
      cluster_name         = module.eks.cluster_name
      namespace            = local.workload_identities["load_balancer_controller"].namespace
      service_account      = local.workload_identities["load_balancer_controller"].service_account
      target_role_arn      = local.pod_identity_target_role_arns["load_balancer_controller"]
      disable_session_tags = try(var.pod_identity.overrides["load_balancer_controller"].disable_session_tags, null)
    }
  }

  permissions_boundary_arn = local.permissions_boundary_arn
  tags                     = var.tags
}

module "ebs_csi_driver_pod_identity" {
  count   = local.pod_identity_enabled["ebs_csi_driver"] ? 1 : 0
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.8.2"

  use_name_prefix         = false
  name                    = "${var.name}-ebs-csi-driver-pod-identity-role"
  aws_ebs_csi_policy_name = "AmazonEKS_EBS_CSI_PodIdentity-${var.name}"

  attach_aws_ebs_csi_policy = local.pod_identity_target_role_arns["ebs_csi_driver"] == null
  attach_custom_policy      = local.pod_identity_target_role_arns["ebs_csi_driver"] != null
  source_policy_documents   = try([data.aws_iam_policy_document.pod_identity_target_role["ebs_csi_driver"].json], [])

  associations = {
    cluster = {
      cluster_name         = module.eks.cluster_name
      namespace            = local.workload_identities["ebs_csi_driver"].namespace
      service_account      = local.workload_identities["ebs_csi_driver"].service_account
      target_role_arn      = local.pod_identity_target_role_arns["ebs_csi_driver"]
      disable_session_tags = try(var.pod_identity.overrides["ebs_csi_driver"].disable_session_tags, null)
    }
  }

  permissions_boundary_arn = local.permissions_boundary_arn
  tags                     = var.tags
}

module "s3_csi_driver_pod_identity" {
  count   = local.pod_identity_enabled["s3_csi_driver"] ? 1 : 0
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.8.2"

  use_name_prefix               = false
  name                          = "${var.name}-s3-csi-driver-pod-identity-role"
  mountpoint_s3_csi_policy_name = "AmazonEKS_Mountpoint_S3_CSI_PodIdentity-${var.name}"

  attach_mountpoint_s3_csi_policy    = local.pod_identity_target_role_arns["s3_csi_driver"] == null && local.attach_s3_csi_policy
  mountpoint_s3_csi_bucket_arns      = local.s3_csi_arns
  mountpoint_s3_csi_bucket_path_arns = [for arn in local.s3_csi_arns : "${arn}/*"]

  attach_custom_policy    = local.pod_identity_target_role_arns["s3_csi_driver"] != null
  source_policy_documents = try([data.aws_iam_policy_document.pod_identity_target_role["s3_csi_driver"].json], [])

  associations = {
    cluster = {
      cluster_name         = module.eks.cluster_name
      namespace            = local.workload_identities["s3_csi_driver"].namespace
      service_account      = local.workload_identities["s3_csi_driver"].service_account
      target_role_arn      = local.pod_identity_target_role_arns["s3_csi_driver"]
      disable_session_tags = try(var.pod_identity.overrides["s3_csi_driver"].disable_session_tags, null)
    }
  }

  permissions_boundary_arn = local.permissions_boundary_arn
  tags                     = var.tags
}

module "external_dns_pod_identity" {
  count   = local.pod_identity_enabled["external_dns"] ? 1 : 0
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.8.2"

  use_name_prefix          = false
  name                     = "${var.name}-external-dns-pod-identity-role"
  external_dns_policy_name = "AmazonEKS_External_DNS_PodIdentity-${var.name}"

  attach_external_dns_policy    = local.pod_identity_target_role_arns["external_dns"] == null
  external_dns_hosted_zone_arns = local.pod_identity_hosted_zone_arns["external_dns"]

  attach_custom_policy    = local.pod_identity_target_role_arns["external_dns"] != null
  source_policy_documents = try([data.aws_iam_policy_document.pod_identity_target_role["external_dns"].json], [])

  associations = {
    cluster = {
      cluster_name         = module.eks.cluster_name
      namespace            = local.workload_identities["external_dns"].namespace
      service_account      = local.workload_identities["external_dns"].service_account
      target_role_arn      = local.pod_identity_target_role_arns["external_dns"]
      disable_session_tags = try(var.pod_identity.overrides["external_dns"].disable_session_tags, null)
    }
  }

  permissions_boundary_arn = local.permissions_boundary_arn
  tags                     = var.tags
}

module "cert_manager_pod_identity" {
  count   = local.pod_identity_enabled["cert_manager"] ? 1 : 0
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.8.2"

  use_name_prefix          = false
  name                     = "${var.name}-cert-manager-pod-identity-role"
  cert_manager_policy_name = "AmazonEKS_Cert_Manager_PodIdentity-${var.name}"

  attach_cert_manager_policy    = local.pod_identity_target_role_arns["cert_manager"] == null
  cert_manager_hosted_zone_arns = local.pod_identity_hosted_zone_arns["cert_manager"]

  attach_custom_policy    = local.pod_identity_target_role_arns["cert_manager"] != null
  source_policy_documents = try([data.aws_iam_policy_document.pod_identity_target_role["cert_manager"].json], [])

  associations = {
    cluster = {
      cluster_name         = module.eks.cluster_name
      namespace            = local.workload_identities["cert_manager"].namespace
      service_account      = local.workload_identities["cert_manager"].service_account
      target_role_arn      = local.pod_identity_target_role_arns["cert_manager"]
      disable_session_tags = try(var.pod_identity.overrides["cert_manager"].disable_session_tags, null)
    }
  }

  permissions_boundary_arn = local.permissions_boundary_arn
  tags                     = var.tags
}
