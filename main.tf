terraform {
  required_version = ">= 1.5.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.14.1"
    }
  }
}
data "aws_partition" "current" {}

locals {
  is_arm = can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", var.stack_fck_nat_instance_type))
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
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
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
  version                                = "6.6.0"
  name                                   = var.stack_name
  create_vpc                             = var.stack_existing_vpc_config == null
  enable_dns_hostnames                   = "true"
  enable_dns_support                     = "true"
  enable_nat_gateway                     = var.stack_fck_nat_enabled != true
  one_nat_gateway_per_az                 = var.stack_fck_nat_enabled != true
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
  count       = var.stack_fck_nat_enabled ? 1 : 0
  most_recent = true
  owners      = [var.stack_fck_nat_ami_owner_id]
  filter {
    name   = "name"
    values = [var.stack_fck_nat_ami_name_filter]
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
  count = var.stack_fck_nat_enabled ? length(module.vpc.azs) : 0
  tags = {
    Name = "nat-${var.stack_name}-${count.index}"
  }
}

module "fck_nat" {
  source             = "RaJiska/fck-nat/aws"
  version            = "1.4.0"
  count              = var.stack_fck_nat_enabled ? length(module.vpc.azs) : 0
  eip_allocation_ids = [aws_eip.main[count.index].allocation_id]
  name               = "${var.stack_name}-${module.vpc.azs[count.index]}"
  ami_id             = data.aws_ami.main[0].id
  vpc_id             = module.vpc.vpc_id
  subnet_id          = module.vpc.public_subnets[count.index]
  # TODO: look to enable agent/spot
  # use_cloudwatch_agent = true
  # use_spot_instances   = true
  instance_type       = var.stack_fck_nat_instance_type
  update_route_tables = true
  route_tables_ids = {
    private = module.vpc.private_route_table_ids[count.index]
  }

  tags = {
    Name = "${var.stack_name}-${module.vpc.azs[count.index]}"
  }
}

data "aws_region" "current" {}

# https://docs.aws.amazon.com/govcloud-us/latest/UserGuide/using-govcloud-vpc-endpoints.html
resource "aws_vpc_endpoint" "eks_vpc_endpoints" {
  for_each     = var.stack_existing_vpc_config == null ? toset(var.vpc_endpoints) : []
  vpc_id       = module.vpc.vpc_id
  service_name = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  tags         = var.stack_tags
}

module "eks" {
  source             = "terraform-aws-modules/eks/aws"
  version            = "21.15.1"
  name               = var.stack_name
  kubernetes_version = var.eks_cluster_version
  create             = var.stack_create
  # TODO: resume usage of node security group; see: https://linear.app/pelotech/issue/PEL-97
  create_node_security_group = false
  endpoint_private_access    = true
  endpoint_public_access     = true
  enabled_log_types          = []

  vpc_id         = var.stack_existing_vpc_config != null ? var.stack_existing_vpc_config.vpc_id : module.vpc.vpc_id
  subnet_ids     = var.stack_existing_vpc_config != null ? var.stack_existing_vpc_config.subnet_ids : module.vpc.private_subnets
  create_kms_key = var.stack_enable_cluster_kms
  enable_irsa    = true
  encryption_config = var.stack_enable_cluster_kms ? {
    "resources" : [
      "secrets"
    ]
  } : {}
  kms_key_administrators = var.stack_enable_cluster_kms ? concat(var.stack_admin_arns, var.stack_ro_arns) : []
  eks_managed_node_groups = var.stack_enable_default_eks_managed_node_group ? {
    "initial-${var.stack_name}" = {
      iam_role_use_name_prefix       = false
      instance_types                 = var.initial_instance_types
      min_size                       = var.initial_node_min_size
      max_size                       = var.initial_node_max_size
      desired_size                   = var.initial_node_desired_size
      ami_type                       = "AL2023_x86_64_STANDARD"
      capacity_type                  = "ON_DEMAND"
      enable_monitoring              = true  # TODO: change from default with upgrade - research impact
      use_latest_ami_release_version = false # TODO: change from default with upgrade - research impact
      metadata_options = {                   # TODO: change from default with upgrade - research impact
        http_endpoint               = "enabled"
        http_put_response_hop_limit = 2
        http_tokens                 = "required"
      }
      labels                = var.initial_node_labels
      cloudinit_pre_nodeadm = var.stack_use_vpc_cni_max_pods ? [] : local.cloudinit_pre_nodeadm
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
      taints = var.initial_node_taints
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
  version                                 = "21.15.1"
  enable_inline_policy                    = true
  cluster_name                            = module.eks.cluster_name
  queue_name                              = var.stack_name
  node_iam_role_name                      = "KarpenterNodeRole-${var.stack_name}"
  iam_role_name                           = "${var.stack_name}-karpenter-role"
  iam_role_use_name_prefix                = false
  node_iam_role_use_name_prefix           = false
  create_pod_identity_association         = false
  iam_role_source_assume_policy_documents = [data.aws_iam_policy_document.source.json]
  tags = merge(var.stack_tags, {
  })
}

# IAM roles and policies for the cluster
module "load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.4.0"

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
  tags = merge(var.stack_tags, {
  })
}

module "ebs_csi_driver_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.4.0"

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
  tags = merge(var.stack_tags, {
  })
}

module "s3_csi" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.10.0"
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
  version = "6.4.0"

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
  tags = merge(var.stack_tags, {
  })
}

module "external_dns_irsa_role" {
  count   = var.stack_create ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.4.0"

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
  tags = merge(var.stack_tags, {
  })
}


module "cert_manager_irsa_role" {
  count   = var.stack_create ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.4.0"

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
  tags = merge(var.stack_tags, {
  })
}
