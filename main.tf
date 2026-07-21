data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

check "initial_node_group_sizing" {
  assert {
    condition     = var.initial_node.min_size <= var.initial_node.desired_size && var.initial_node.desired_size <= var.initial_node.max_size
    error_message = "initial_node sizes must satisfy: min (${var.initial_node.min_size}) <= desired (${var.initial_node.desired_size}) <= max (${var.initial_node.max_size})."
  }
}

locals {
  permissions_boundary_arn = var.permissions_boundary != "" ? "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.permissions_boundary}" : null
  is_arm                   = can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", var.pelotech_nat.instance_type))
  # Derive the node AMI arch from the requested instance types (Graviton family
  # names carry a "g", e.g. m7g/c6gd/t4g). Same detection as is_arm above; the
  # a1 family (no "g") is not detected. initial_node.instance_types validates arch
  # agreement, so index [0] is representative.
  initial_is_arm = can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", var.initial_node.instance_types[0]))
  # One expansion for the three managed access groups. The map keys ("admin_0",
  # "admin_ro_0", "ro_0", ...) and association keys are state addresses inside the
  # EKS module's for_each — keep them stable to avoid access-entry churn.
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

  # OVERWRITE on create lets AWS adopt any pre-existing self-managed daemonsets into the managed-addons API.
  # before_compute on vpc-cni installs the addon ahead of node groups so pods get IPs immediately.
  # preserve=false overrides the upstream module default (true) so disabling an addon also removes
  # its underlying workload (e.g. aws-node DaemonSet) — required for clean CNI swaps.
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
    "coredns" = {
      most_recent                 = true
      preserve                    = false
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values = jsonencode({
        tolerations = [
          {
            operator = "Exists"
          }
        ]
      })
    }
  }
  # CNI profiles: var.cni selects the taints/labels and vpc-cni/kube-proxy addon
  # enablement appropriate for the chosen CNI. Individual pieces stay overridable
  # (initial_node.taints(_extra)/labels(_extra) and the addons toggles).
  # `system_node` describes the initial/system node group's taints/labels (coredns +
  # critical addons). `cni_node` (null unless the CNI needs it) describes, with the
  # same shape, a dedicated node group for the CNI's control plane — kube-ovn's
  # ovn-central, which pins to its master nodes' IPs and so must be recycled
  # (destroy/recreate) rather than rolled.
  cni_profiles = {
    cilium = {
      system_node = {
        taints = {
          critical_addons_only = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
          cilium               = { key = "node.cilium.io/agent-not-ready", value = "true", effect = "NO_EXECUTE" }
        }
        labels = {}
      }
      cni_node                = null
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
      enable_vpc_cni_addon    = true
      enable_kube_proxy_addon = true
    }
  }
  cni_profile = local.cni_profiles[var.cni]

  # Override model: full-override var wins entirely (null = derive); otherwise preset + _extra merge.
  initial_taints = var.initial_node.taints != null ? var.initial_node.taints : merge(local.cni_profile.system_node.taints, var.initial_node.taints_extra)
  initial_labels = var.initial_node.labels != null ? var.initial_node.labels : merge(local.cni_profile.system_node.labels, var.initial_node.labels_extra)

  # Dedicated CNI node group (kube-ovn control plane): exists only for profiles that
  # define cni_node, and can be toggled off (recycle) via var.cni_node.enabled.
  enable_cni_node_group   = local.cni_profile.cni_node != null && coalesce(var.cni_node.enabled, true)
  cni_node_taints         = try(local.cni_profile.cni_node.taints, {})
  cni_node_labels         = try(local.cni_profile.cni_node.labels, {})
  cni_node_instance_types = coalesce(var.cni_node.instance_types, var.initial_node.instance_types)
  cni_node_is_arm         = can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", local.cni_node_instance_types[0]))

  # Settings shared by both managed node groups (per-group bits merged on top below).
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

  # Addon toggles: explicit bool wins; null = derive from CNI profile.
  enable_vpc_cni_addon    = var.addons.vpc_cni != null ? var.addons.vpc_cni : local.cni_profile.enable_vpc_cni_addon
  enable_kube_proxy_addon = var.addons.kube_proxy != null ? var.addons.kube_proxy : local.cni_profile.enable_kube_proxy_addon

  cluster_addons_enabled = {
    "vpc-cni"    = local.enable_vpc_cni_addon
    "kube-proxy" = local.enable_kube_proxy_addon
    "coredns"    = var.addons.coredns
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
  tags = merge(var.tags, {
  })
}

locals {
  nat_tailscale_enabled = var.pelotech_nat.enabled && var.pelotech_nat.tailscale.enabled
  # Module creates the SSM parameter when a plain key is supplied
  nat_tailscale_create_ssm = local.nat_tailscale_enabled && var.pelotech_nat_tailscale_auth_key != ""
  # Effective SSM parameter name - the XOR validation on the variable guarantees exactly one source
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

  # Appended after the fck-nat module's own user_data part, which writes the
  # base /etc/fck-nat.conf and restarts the service. Quoted heredoc so nothing
  # is shell-expanded at boot.
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
  tags = {
    Name = "nat-${var.name}-${count.index}"
  }
}

module "fck_nat" {
  source             = "RaJiska/fck-nat/aws"
  version            = "1.6.0"
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
  cloud_init_parts    = local.nat_tailscale_enabled ? [local.nat_tailscale_cloud_init_by_az[module.vpc.azs[count.index]]] : []
  update_route_tables = true
  route_tables_ids = {
    private = module.vpc.private_route_table_ids[count.index]
  }

  tags = {
    Name = "${var.name}-${module.vpc.azs[count.index]}"
  }
}

data "aws_region" "current" {}

# Private VPC endpoints so nodes reach ECR/STS/SSM/EC2 (and are SSM-debuggable)
# without depending on NAT egress. Kubelet->API already works privately via the
# cluster's endpoint_private_access ENIs. Opt-in by listing services in
# var.vpc_endpoints (empty = none). Internal (module-created) VPC only.
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

  # s3/dynamodb are free Gateway endpoints (routed via the private route tables);
  # everything else is an Interface endpoint. Each service is opt-in via the list,
  # so e.g. vpc_endpoints = ["s3"] provisions only the S3 gateway.
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
  version                       = "21.24.0"
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
  enable_irsa                   = true
  encryption_config = var.create_cluster_kms ? {
    "resources" : [
      "secrets"
    ]
  } : {}
  kms_key_administrators = var.create_cluster_kms ? concat(var.access.admin_arns, var.access.admin_ro_arns) : []
  eks_managed_node_groups = merge(
    # Initial / system group (coredns + critical addons). Follows the control-plane
    # version and rolls in place on upgrade.
    var.initial_node.enabled ? {
      "initial-${var.name}" = merge(local.node_group_common, {
        instance_types = var.initial_node.instance_types
        min_size       = var.initial_node.min_size
        max_size       = var.initial_node.max_size
        desired_size   = var.initial_node.desired_size
        ami_type       = local.initial_is_arm ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"
        labels         = local.initial_labels
        taints         = local.initial_taints
      })
    } : {},
    # Dedicated CNI control-plane group (kube-ovn). Version-pinned and recycled
    # (destroy/recreate) on upgrade so the initial group + coredns are untouched.
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
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = var.name
  })
}
data "aws_iam_policy_document" "source" { # allow usage with irsa
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
  count                                   = var.create ? 1 : 0
  source                                  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version                                 = "21.24.0"
  enable_inline_policy                    = true
  cluster_name                            = module.eks.cluster_name
  queue_name                              = var.name
  node_iam_role_name                      = "KarpenterNodeRole-${var.name}"
  iam_role_name                           = "${var.name}-karpenter-role"
  iam_role_use_name_prefix                = false
  node_iam_role_use_name_prefix           = false
  create_pod_identity_association         = false
  iam_role_permissions_boundary_arn       = local.permissions_boundary_arn
  node_iam_role_permissions_boundary      = local.permissions_boundary_arn
  iam_role_source_assume_policy_documents = [data.aws_iam_policy_document.source.json]
  tags = merge(var.tags, {
  })
}

# IAM roles and policies for the cluster
module "load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

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
  tags = merge(var.tags, {
  })
}

module "ebs_csi_driver_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

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
  tags = merge(var.tags, {
  })
}

module "s3_csi" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.15.1"
  bucket  = "${var.tags.Owner}-${var.name}-csi-bucket"

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
  tags = merge(var.tags, {
  })
}

module "s3_driver_irsa_role" {
  count   = var.create ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

  use_name_prefix = false
  name            = "${var.name}-s3-csi-driver-role"
  policy_name     = "AmazonEKS_Mountpoint_S3_CSI-${var.name}"

  attach_mountpoint_s3_csi_policy = true
  mountpoint_s3_csi_bucket_arns   = local.s3_csi_arns
  mountpoint_s3_csi_path_arns     = [for arn in local.s3_csi_arns : "${arn}/*"]
  oidc_providers = {
    cluster = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:s3-csi-driver"]
    }
  }
  permissions_boundary = local.permissions_boundary_arn
  tags = merge(var.tags, {
  })
}

module "external_dns_irsa_role" {
  count   = var.create ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

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
  tags = merge(var.tags, {
  })
}


module "cert_manager_irsa_role" {
  count   = var.create ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

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
  tags = merge(var.tags, {
  })
}
