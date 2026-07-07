variable "stack_name" {
  type        = string
  default     = "foundation-stack"
  description = "Name of the stack"
}

variable "stack_create" {
  type        = bool
  default     = true
  description = "should resources be created"
}

variable "stack_create_pelotech_nat_eip" {
  type        = bool
  default     = false
  description = "should create pelotech nat eip even if NAT isn't enabled - nice for getting ips created for allow lists"
}

variable "eks_cluster_version" {
  type        = string
  default     = "1.35"
  description = "Kubernetes version to set for the cluster"

  validation {
    condition     = can(regex("^\\d+\\.\\d+$", var.eks_cluster_version))
    error_message = "eks_cluster_version must be in MAJOR.MINOR form (e.g. \"1.35\")."
  }
}

variable "stack_tags" {
  type = map(string)
  default = {
    Owner       = "pelotech"
    Environment = "prod"
  }
  description = "tags to be added to the stack, should at least have Owner and Environment"
}

variable "stack_cni" {
  type        = string
  default     = "cilium"
  description = "CNI profile driving the initial node group taints/labels and vpc-cni/kube-proxy addon enablement. One of: cilium, kube-ovn, vpc-cni. Override individual pieces with initial_node_taints(_extra)/initial_node_labels(_extra) and the stack_enable_*_addon toggles."
  validation {
    condition     = contains(["cilium", "kube-ovn", "vpc-cni"], var.stack_cni)
    error_message = "stack_cni must be one of: cilium, kube-ovn, vpc-cni."
  }
}

variable "stack_enable_vpc_cni_addon" {
  type        = bool
  default     = null
  description = "Override installation of the AWS VPC CNI managed addon. Leave null (default) to derive from stack_cni (on for vpc-cni, off for cilium/kube-ovn). Set true/false to force. When the addon is off, nodeadm maxPods=110 cloudinit is applied automatically."
}

variable "stack_enable_kube_proxy_addon" {
  type        = bool
  default     = null
  description = "Override installation of the kube-proxy managed addon. Leave null (default) to derive from stack_cni (off for cilium kube-proxy replacement, on for kube-ovn/vpc-cni). Set true/false to force."
}

variable "stack_enable_coredns_addon" {
  type        = bool
  default     = true
  description = "Install coredns as a managed addon. Note: coredns will not schedule until a CNI is running and nodes are Ready."
}

variable "stack_cluster_addons_overrides" {
  type        = any
  default     = {}
  description = "Per-addon overrides keyed by addon name (e.g. \"vpc-cni\", \"kube-proxy\", \"coredns\"). Merges over module defaults — use for version pinning, vpc-cni prefix delegation, custom networking, etc. Accepts any attributes supported by terraform-aws-modules/eks/aws v21+ `addons` map."
}

variable "stack_enable_cluster_kms" {
  type        = bool
  default     = true
  description = "Should secrets be encrypted by kms in the cluster"
}

variable "stack_enable_default_eks_managed_node_group" {
  type        = bool
  default     = true
  description = "Ability to disable default node group"
}

variable "stack_pelotech_nat_enabled" {
  type        = bool
  default     = false
  description = "Use pelotech-nat as NAT instances instead of NAT gateway"
}

variable "stack_pelotech_nat_ami_owner_id" {
  type        = string
  default     = "568608671756"
  description = "Owner ID to search of ami"
}

variable "stack_pelotech_nat_ami_name_filter" {
  type        = string
  default     = "fck-nat-al2023-hvm-*"
  description = "ami name filter to find the correct ami"
}

variable "stack_pelotech_nat_instance_type" {
  type        = string
  default     = "t4g.micro"
  description = "choose instance based on bandwitch requirements"
}

variable "stack_existing_vpc_config" {
  type = object({
    vpc_id     = string
    subnet_ids = list(string)
  })
  default     = null
  description = "Setting the VPC"
}

variable "stack_vpc_block" {
  type = object({
    cidr             = string
    azs              = list(string)
    private_subnets  = list(string)
    public_subnets   = list(string)
    database_subnets = list(string)
  })
  default = {
    cidr             = "172.16.0.0/16"
    azs              = ["us-west-2a", "us-west-2b", "us-west-2c"]
    private_subnets  = ["172.16.0.0/24", "172.16.1.0/24", "172.16.2.0/24"]
    public_subnets   = ["172.16.100.0/24", "172.16.101.0/24", "172.16.102.0/24"]
    database_subnets = ["172.16.200.0/24", "172.16.201.0/24", "172.16.202.0/24"]
  }
  description = "Variables for defining the vpc for the stack"
}

variable "extra_access_entries" {
  type = list(object({
    principal_arn     = string
    kubernetes_groups = optional(list(string))
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        type       = string
        namespaces = optional(list(string))
      })
    })), {})

  }))
  description = "EKS access entries needed by IAM roles interacting with this cluster"
  default     = []

  validation {
    error_message = "The access scope type can only be 'namespace' or 'cluster'"
    condition = alltrue([
      for entry in var.extra_access_entries : ((entry.policy_associations == null) || alltrue([
        for policy in values(entry.policy_associations) : contains(["namespace", "cluster"], policy.access_scope.type)
      ]))
    ])
  }

  validation {
    error_message = "The access scope type 'namespace' requires 'namespaces', namespaces can't be set otherwise."
    condition = alltrue([
      for entry in var.extra_access_entries : ((entry.policy_associations == null) || alltrue([
        for policy in values(entry.policy_associations) : ((policy.access_scope.type == "namespace" && policy.access_scope.namespaces != null) || policy.access_scope.type == "cluster" && policy.access_scope.namespaces == null)
      ]))
    ])
  }
}

variable "stack_admin_arns" {
  type        = list(string)
  default     = []
  description = "arn to the roles for the cluster admins role"
}

variable "stack_ro_arns" {
  type        = list(string)
  default     = []
  description = "arn to the roles for the cluster read only role, these will also have KMS readonly access for CI plan purposes, more limited access should use the extra entries"
}

variable "initial_node_taints" {
  type        = map(object({ key = string, value = string, effect = string }))
  default     = null
  description = "Full override of the initial managed node group taints. Leave null (default) to derive from stack_cni merged with initial_node_taints_extra. Set to a map to replace the CNI preset entirely (use {} for no taints)."
}

variable "initial_node_taints_extra" {
  type        = map(object({ key = string, value = string, effect = string }))
  default     = {}
  description = "Extra taints merged over the stack_cni preset for the initial managed node group (caller keys win). Ignored when initial_node_taints is set."
}

variable "initial_node_labels" {
  type        = map(string)
  default     = null
  description = "Full override of the initial managed node group labels. Leave null (default) to derive from stack_cni merged with initial_node_labels_extra. Set to a map to replace the CNI preset entirely (use {} for no labels)."
}

variable "initial_node_labels_extra" {
  type        = map(string)
  default     = {}
  description = "Extra labels merged over the stack_cni preset for the initial managed node group (caller keys win). Ignored when initial_node_labels is set."
}

variable "initial_instance_types" {
  type        = list(string)
  description = "instance types of the initial managed node group (must all be the same architecture; the node AMI type is derived from them)"

  validation {
    condition     = length(var.initial_instance_types) > 0
    error_message = "initial_instance_types must not be empty."
  }
  validation {
    # All types must share one architecture (all Graviton/arm64 or all x86_64),
    # since the derived ami_type applies to the whole node group.
    condition     = length(distinct([for t in var.initial_instance_types : can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", t))])) <= 1
    error_message = "All initial_instance_types must be the same architecture (all Graviton/arm64 or all x86_64)."
  }
}

variable "initial_node_timeouts" {
  type = object({
    create = optional(string)
    update = optional(string)
    delete = optional(string)
  })
  default     = null
  description = "Timeouts for the initial managed node group's create/update/delete. null uses the AWS provider default (60m create). Set e.g. { create = \"20m\" } to fail fast when a CNI-less cluster's nodes never reach Ready."
}

variable "initial_node_min_size" {
  type        = number
  default     = 2
  description = "minimum size of the initial managed node group"

  validation {
    condition     = var.initial_node_min_size >= 0
    error_message = "initial_node_min_size must be >= 0."
  }
}

variable "initial_node_max_size" {
  type        = number
  default     = 6
  description = "max size of the initial managed node group"
}

variable "initial_node_desired_size" {
  type        = number
  default     = 3
  description = "desired size of the initial managed node group"
}

variable "s3_csi_driver_create_bucket" {
  type        = bool
  default     = true
  description = "create a new bucket for use with the s3 CSI driver"
}

variable "s3_csi_driver_bucket_arns" {
  type        = list(string)
  default     = []
  description = "existing buckets the s3 CSI driver should have access to"
}

variable "vpc_endpoints" {
  type = list(string)
  # VPC endpoint service short-names to create (empty = none). "s3" and "dynamodb"
  # are provisioned as free Gateway endpoints; every other name is an Interface
  # endpoint. Each is opt-in, so e.g. ["s3"] creates only the S3 gateway. Interface
  # endpoints let private nodes reach ECR/STS/SSM/EC2 and be SSM-debuggable without
  # NAT egress (kubelet->API already works privately via the cluster's
  # endpoint_private_access ENIs). Internal (module-created) VPC only.
  # Cost: Gateway endpoints (s3/dynamodb) are free; Interface endpoints are ~$7/mo
  # each per AZ (≈ $22/mo per service across 3 AZs) plus data processing.
  # Recommended set for private/NAT-resilient clusters:
  # ["s3","ssm","ssmmessages","ec2messages","ec2","ecr.api","ecr.dkr","sts","elasticloadbalancing","autoscaling"]
  description = "VPC endpoint service short-names to create (empty = none). s3/dynamodb are free Gateway endpoints; others are Interface endpoints. See the variable comment for the recommended set and cost. Internal VPC only."
  default     = []
}

variable "node_iam_additional_policies" {
  type        = map(string)
  default     = {}
  description = "Map of IAM policy name to ARN to attach to the managed node group IAM role."
}

variable "cluster_enabled_log_types" {
  type        = list(string)
  default     = []
  description = "List of EKS control plane log types to enable. Valid values: api, audit, authenticator, controllerManager, scheduler."

  validation {
    condition = alltrue([
      for t in var.cluster_enabled_log_types : contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)
    ])
    error_message = "cluster_enabled_log_types entries must be one of: api, audit, authenticator, controllerManager, scheduler."
  }
}

variable "cluster_endpoint_public_access" {
  type        = bool
  default     = true
  description = "Whether the EKS cluster API server endpoint is publicly accessible. Set to false for private-only access (requires VPC connectivity)."
}

# TODO: resume usage of node security group; see: https://linear.app/pelotech/issue/PEL-97
variable "create_node_security_group" {
  type        = bool
  default     = false
  description = "Whether to create a dedicated security group for EKS managed node groups. When true, the node_security_group_id output is populated."
}

variable "permissions_boundary" {
  type        = string
  default     = ""
  description = "IAM permissions boundary policy name applied to all IAM roles. When set, constructs full ARN from the current account and partition."
}

variable "pre_bootstrap_user_data" {
  type        = string
  default     = null
  description = "Custom user data script to run before node bootstrap. Useful for installing CA certificates or custom packages."
}
