data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

check "initial_node_group_sizing" {
  assert {
    condition     = var.initial_node_min_size <= var.initial_node_desired_size && var.initial_node_desired_size <= var.initial_node_max_size
    error_message = "initial_node sizes must satisfy: min (${var.initial_node_min_size}) <= desired (${var.initial_node_desired_size}) <= max (${var.initial_node_max_size})."
  }
}

locals {
  permissions_boundary_arn = var.permissions_boundary != "" ? "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.permissions_boundary}" : null
  is_arm                   = can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", var.stack_pelotech_nat_instance_type))
  # Derive the node AMI arch from the requested instance types (Graviton family
  # names carry a "g", e.g. m7g/c6gd/t4g). Same detection as is_arm above; the
  # a1 family (no "g") is not detected. initial_instance_types validates arch
  # agreement, so index [0] is representative.
  initial_is_arm = can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", var.initial_instance_types[0]))
  admin_access_entries = {
    for index, item in var.stack_admin_arns : "admin_${index}" => {
      principal_arn = item
      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
  ro_access_entries = {
    for index, item in var.stack_ro_arns : "ro_${index}" => {
      principal_arn = item
      policy_associations = {
        view_only = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
  extra_access_entries = {
    for index, item in var.extra_access_entries : "extra_${index}" => item
  }
  s3_csi_arns = compact(concat([module.s3_csi.s3_bucket_arn], var.s3_csi_driver_bucket_arns))

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
  # CNI profiles: stack_cni selects the taints/labels and vpc-cni/kube-proxy addon
  # enablement appropriate for the chosen CNI. Individual pieces stay overridable
  # (initial_node_taints(_extra)/initial_node_labels(_extra) and the addon toggles).
  cni_profiles = {
    cilium = {
      taints = {
        critical_addons_only = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
        cilium               = { key = "node.cilium.io/agent-not-ready", value = "true", effect = "NO_EXECUTE" }
      }
      labels                  = {}
      enable_vpc_cni_addon    = false
      enable_kube_proxy_addon = false # cilium kube-proxy replacement
    }
    "kube-ovn" = {
      taints = {
        critical_addons_only = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
        nidhogg              = { key = "nidhogg.uswitch.com/kube-system.kube-multus-ds", value = "true", effect = "NO_SCHEDULE" }
      }
      labels                  = { "kube-ovn/role" = "master" }
      enable_vpc_cni_addon    = false
      enable_kube_proxy_addon = true
    }
    "vpc-cni" = {
      taints = {
        critical_addons_only = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
      }
      labels                  = {}
      enable_vpc_cni_addon    = true
      enable_kube_proxy_addon = true
    }
  }
  cni = local.cni_profiles[var.stack_cni]

  # Override model: full-override var wins entirely (null = derive); otherwise preset + _extra merge.
  initial_taints = var.initial_node_taints != null ? var.initial_node_taints : merge(local.cni.taints, var.initial_node_taints_extra)
  initial_labels = var.initial_node_labels != null ? var.initial_node_labels : merge(local.cni.labels, var.initial_node_labels_extra)

  # Addon toggles: explicit bool wins; null = derive from CNI profile.
  enable_vpc_cni_addon    = var.stack_enable_vpc_cni_addon != null ? var.stack_enable_vpc_cni_addon : local.cni.enable_vpc_cni_addon
  enable_kube_proxy_addon = var.stack_enable_kube_proxy_addon != null ? var.stack_enable_kube_proxy_addon : local.cni.enable_kube_proxy_addon

  cluster_addons_enabled = {
    "vpc-cni"    = local.enable_vpc_cni_addon
    "kube-proxy" = local.enable_kube_proxy_addon
    "coredns"    = var.stack_enable_coredns_addon
  }
  cluster_addons = {
    for name, enabled in local.cluster_addons_enabled : name =>
    merge(local.cluster_addon_defaults[name], try(var.stack_cluster_addons_overrides[name], {}))
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
  name                                   = var.stack_name
  create_vpc                             = var.stack_existing_vpc_config == null
  enable_dns_hostnames                   = "true"
  enable_dns_support                     = "true"
  enable_nat_gateway                     = var.stack_pelotech_nat_enabled != true
  one_nat_gateway_per_az                 = var.stack_pelotech_nat_enabled != true
  cidr                                   = var.stack_vpc_block.cidr
  azs                                    = var.stack_vpc_block.azs
  private_subnets                        = var.stack_vpc_block.private_subnets
  public_subnets                         = var.stack_vpc_block.public_subnets
  database_subnets                       = var.stack_vpc_block.database_subnets
  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "karpenter.sh/discovery"          = var.stack_name
    "kubernetes.io/role/internal-elb" = 1
  }
  tags = merge(var.stack_tags, {
  })
}

data "aws_ami" "main" {
  count       = var.stack_pelotech_nat_enabled ? 1 : 0
  most_recent = true
  owners      = [var.stack_pelotech_nat_ami_owner_id]
  filter {
    name   = "name"
    values = [var.stack_pelotech_nat_ami_name_filter]
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
  count = (var.stack_pelotech_nat_enabled || var.stack_create_pelotech_nat_eip) ? length(module.vpc.azs) : 0
  tags = {
    Name = "nat-${var.stack_name}-${count.index}"
  }
}

module "fck_nat" {
  source             = "RaJiska/fck-nat/aws"
  version            = "1.6.0"
  count              = var.stack_pelotech_nat_enabled ? length(module.vpc.azs) : 0
  eip_allocation_ids = [aws_eip.main[count.index].allocation_id]
  name               = "${var.stack_name}-${module.vpc.azs[count.index]}"
  ami_id             = data.aws_ami.main[0].id
  vpc_id             = module.vpc.vpc_id
  subnet_id          = module.vpc.public_subnets[count.index]
  # TODO: look to enable agent/spot
  # use_cloudwatch_agent = true
  # use_spot_instances   = true
  instance_type       = var.stack_pelotech_nat_instance_type
  update_route_tables = true
  route_tables_ids = {
    private = module.vpc.private_route_table_ids[count.index]
  }

  tags = {
    Name = "${var.stack_name}-${module.vpc.azs[count.index]}"
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
  count   = var.stack_existing_vpc_config == null && length(var.vpc_endpoints) > 0 ? 1 : 0

  vpc_id = module.vpc.vpc_id

  create_security_group      = true
  security_group_name_prefix = "${var.stack_name}-vpce-"
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

  tags = var.stack_tags
}

module "eks" {
  source                        = "terraform-aws-modules/eks/aws"
  version                       = "21.24.0"
  name                          = var.stack_name
  kubernetes_version            = var.eks_cluster_version
  create                        = var.stack_create
  create_node_security_group    = var.create_node_security_group
  iam_role_permissions_boundary = local.permissions_boundary_arn
  endpoint_private_access       = true
  endpoint_public_access        = var.cluster_endpoint_public_access
  enabled_log_types             = var.cluster_enabled_log_types
  vpc_id                        = var.stack_existing_vpc_config != null ? var.stack_existing_vpc_config.vpc_id : module.vpc.vpc_id
  subnet_ids                    = var.stack_existing_vpc_config != null ? var.stack_existing_vpc_config.subnet_ids : module.vpc.private_subnets
  addons                        = local.cluster_addons
  create_kms_key                = var.stack_enable_cluster_kms
  enable_irsa                   = true
  encryption_config = var.stack_enable_cluster_kms ? {
    "resources" : [
      "secrets"
    ]
  } : {}
  kms_key_administrators = var.stack_enable_cluster_kms ? concat(var.stack_admin_arns, var.stack_ro_arns) : []
  eks_managed_node_groups = var.stack_enable_default_eks_managed_node_group ? {
    "initial-${var.stack_name}" = {
      iam_role_use_name_prefix       = false
      iam_role_permissions_boundary  = local.permissions_boundary_arn
      instance_types                 = var.initial_instance_types
      min_size                       = var.initial_node_min_size
      max_size                       = var.initial_node_max_size
      desired_size                   = var.initial_node_desired_size
      ami_type                       = local.initial_is_arm ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"
      capacity_type                  = "ON_DEMAND"
      enable_monitoring              = true  # TODO: change from default with upgrade - research impact
      use_latest_ami_release_version = false # TODO: change from default with upgrade - research impact
      metadata_options = {                   # TODO: change from default with upgrade - research impact
        http_endpoint               = "enabled"
        http_put_response_hop_limit = 2
        http_tokens                 = "required"
      }
      labels                  = local.initial_labels
      cloudinit_pre_nodeadm   = local.enable_vpc_cni_addon ? [] : local.cloudinit_pre_nodeadm
      pre_bootstrap_user_data = var.pre_bootstrap_user_data
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
      taints                       = local.initial_taints
      iam_role_additional_policies = var.node_iam_additional_policies
      timeouts                     = var.initial_node_timeouts
    }
  } : {}
  access_entries = merge(local.admin_access_entries, local.ro_access_entries, local.extra_access_entries)
  tags = merge(var.stack_tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = var.stack_name
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
  count                                   = var.stack_create ? 1 : 0
  source                                  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version                                 = "21.24.0"
  enable_inline_policy                    = true
  cluster_name                            = module.eks.cluster_name
  queue_name                              = var.stack_name
  node_iam_role_name                      = "KarpenterNodeRole-${var.stack_name}"
  iam_role_name                           = "${var.stack_name}-karpenter-role"
  iam_role_use_name_prefix                = false
  node_iam_role_use_name_prefix           = false
  create_pod_identity_association         = false
  iam_role_permissions_boundary_arn       = local.permissions_boundary_arn
  node_iam_role_permissions_boundary      = local.permissions_boundary_arn
  iam_role_source_assume_policy_documents = [data.aws_iam_policy_document.source.json]
  tags = merge(var.stack_tags, {
  })
}

# IAM roles and policies for the cluster
module "load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

  use_name_prefix = false
  name            = "${var.stack_name}-alb-role"
  policy_name     = "AmazonEKS_AWS_Load_Balancer_Controller-${var.stack_name}"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    cluster = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["alb:aws-load-balancer-controller"]
    }
  }
  permissions_boundary = local.permissions_boundary_arn
  tags = merge(var.stack_tags, {
  })
}

module "ebs_csi_driver_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

  use_name_prefix = false
  name            = "${var.stack_name}-ebs-csi-driver-role"
  policy_name     = "AmazonEKS_EBS_CSI_Policy-${var.stack_name}"

  attach_ebs_csi_policy = true

  oidc_providers = {
    cluster = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-driver"]
    }
  }
  permissions_boundary = local.permissions_boundary_arn
  tags = merge(var.stack_tags, {
  })
}

module "s3_csi" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.14.1"
  bucket  = "${var.stack_tags.Owner}-${var.stack_name}-csi-bucket"

  create_bucket                         = var.s3_csi_driver_create_bucket
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
  tags = merge(var.stack_tags, {
  })
}

module "s3_driver_irsa_role" {
  count   = var.stack_create ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

  use_name_prefix = false
  name            = "${var.stack_name}-s3-csi-driver-role"
  policy_name     = "AmazonEKS_Mountpoint_S3_CSI-${var.stack_name}"

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
  tags = merge(var.stack_tags, {
  })
}

module "external_dns_irsa_role" {
  count   = var.stack_create ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

  use_name_prefix = false
  name            = "${var.stack_name}-external-dns-role"
  policy_name     = "AmazonEKS_External_DNS_Policy-${var.stack_name}"

  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["*"]

  oidc_providers = {
    cluster = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns-controller"]
    }
  }
  permissions_boundary = local.permissions_boundary_arn
  tags = merge(var.stack_tags, {
  })
}


module "cert_manager_irsa_role" {
  count   = var.stack_create ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

  use_name_prefix = false
  name            = "${var.stack_name}-cert-manager-role"
  policy_name     = "AmazonEKS_Cert_Manager_Policy-${var.stack_name}"

  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = ["*"]

  oidc_providers = {
    cluster = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }
  permissions_boundary = local.permissions_boundary_arn
  tags = merge(var.stack_tags, {
  })
}
