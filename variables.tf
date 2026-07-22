variable "initial_node" {
  description = "Initial (system) managed node group. instance_types is required and must all be one architecture (the node AMI type is derived from them). taints/labels: leave null to derive from the cni profile merged with taints_extra/labels_extra (caller keys win); set to a map to replace the preset entirely ({} for none). force_update_version: evict through PodDisruptionBudgets when a version roll exhausts the per-node eviction window (escape hatch for PodEvictionFailure; pods blocked by a PDB are deleted). Default false."
  type = object({
    instance_types       = list(string)
    enabled              = optional(bool, true)
    min_size             = optional(number, 2)
    max_size             = optional(number, 6)
    desired_size         = optional(number, 3)
    force_update_version = optional(bool, false)
    taints               = optional(map(object({ key = string, value = string, effect = string })))
    taints_extra         = optional(map(object({ key = string, value = string, effect = string })), {})
    labels               = optional(map(string))
    labels_extra         = optional(map(string), {})
    timeouts = optional(object({
      create = optional(string)
      update = optional(string)
      delete = optional(string)
    }))
  })
  nullable = false

  validation {
    condition     = length(var.initial_node.instance_types) > 0
    error_message = "initial_node.instance_types must not be empty."
  }
  validation {
    # All types must share one architecture (all Graviton/arm64 or all x86_64),
    # since the derived ami_type applies to the whole node group.
    condition     = length(distinct([for t in var.initial_node.instance_types : can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", t))])) <= 1
    error_message = "All initial_node.instance_types must be the same architecture (all Graviton/arm64 or all x86_64)."
  }
  validation {
    condition     = var.initial_node.min_size >= 0
    error_message = "initial_node.min_size must be >= 0."
  }
}

variable "name" {
  type        = string
  default     = "foundation-stack"
  description = "Name of the stack"
}

variable "create" {
  type        = bool
  default     = true
  description = "should resources be created"
}

variable "cluster_version" {
  type        = string
  default     = "1.35"
  description = "Kubernetes version to set for the cluster"

  validation {
    condition     = can(regex("^\\d+\\.\\d+$", var.cluster_version))
    error_message = "cluster_version must be in MAJOR.MINOR form (e.g. \"1.35\")."
  }
}

variable "tags" {
  type = map(string)
  default = {
    Owner       = "pelotech"
    Environment = "prod"
  }
  description = "tags to be added to the stack, should at least have Owner and Environment"
}

variable "cni" {
  type        = string
  default     = "cilium"
  description = "CNI profile driving the initial (system) node group taints/labels and vpc-cni/kube-proxy addon enablement. One of: cilium, kube-ovn, vpc-cni. For kube-ovn the system group carries the nidhogg gating taints, while the kube-ovn/role=master label + control-plane taint go to a dedicated CNI node group (the cni_node variable). Override individual pieces with initial_node.taints(_extra)/labels(_extra) and the addons toggles."
  validation {
    condition     = contains(["cilium", "kube-ovn", "vpc-cni"], var.cni)
    error_message = "cni must be one of: cilium, kube-ovn, vpc-cni."
  }
}

variable "addons" {
  description = "Managed cluster addon toggles and overrides. vpc_cni/kube_proxy: leave null (default) to derive from the cni profile (vpc-cni: on for cni=vpc-cni; kube-proxy: off for cilium kube-proxy replacement); set true/false to force. When the vpc-cni addon is off, nodeadm maxPods=110 cloudinit is applied automatically. overrides: per-addon overrides keyed by addon name (e.g. \"vpc-cni\", \"kube-proxy\", \"coredns\") merged over module defaults — accepts any attributes supported by terraform-aws-modules/eks/aws v21+ `addons` map."
  type = object({
    vpc_cni    = optional(bool)
    kube_proxy = optional(bool)
    coredns    = optional(bool, true)
    overrides  = optional(any, {})
  })
  default  = {}
  nullable = false
}

variable "create_cluster_kms" {
  type        = bool
  default     = true
  description = "Should secrets be encrypted by kms in the cluster"
}

variable "pelotech_nat" {
  description = "Pelotech NAT instances replacing the managed NAT gateway — a hardened fck-nat-based image (FIPS, L2 compliance, optional Tailscale) from AWS Marketplace. IMPORTANT: the default AMI is the Pelotech NAT image from AWS Marketplace and requires an active Marketplace subscription in the target account — without one the instance launch fails at apply time with OptInRequired. Subscribe first, or point ami_owner_id/ami_name_filter at your own image. create_eip creates the NAT EIP even when enabled=false — nice for getting ips created for allow lists. tailscale: provide auth via tailscale.auth_key_ssm (name of an existing SSM parameter) or pelotech_nat_tailscale_auth_key (plain key; the module stores it in a SecureString SSM parameter it creates). The instances always read the key from SSM. SecureString params under the default aws/ssm KMS key work as-is; customer-managed KMS keys on an existing parameter require a key-policy grant outside this module."
  type = object({
    enabled         = optional(bool, false)
    instance_type   = optional(string, "t4g.micro")
    ami_owner_id    = optional(string, "aws-marketplace")
    ami_name_filter = optional(string, "pelotech-nat-al2023-hvm-*")
    create_eip      = optional(bool, false)
    tailscale = optional(object({
      enabled            = optional(bool, false)
      auth_key_ssm       = optional(string, "")
      advertise_routes   = optional(string, "")
      exit_node          = optional(bool, false)
      hostname           = optional(string, "")
      snat_subnet_routes = optional(bool, true)
      extra_args         = optional(string, "")
    }), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = !var.pelotech_nat.tailscale.enabled || (var.pelotech_nat.tailscale.auth_key_ssm != "") != (var.pelotech_nat_tailscale_auth_key != "")
    error_message = "When tailscale is enabled, set exactly one of pelotech_nat_tailscale_auth_key or pelotech_nat.tailscale.auth_key_ssm."
  }
  validation {
    condition = alltrue([for v in [
      var.pelotech_nat.tailscale.auth_key_ssm,
      var.pelotech_nat.tailscale.advertise_routes,
      var.pelotech_nat.tailscale.hostname,
      var.pelotech_nat.tailscale.extra_args,
    ] : !strcontains(v, "\"") && !strcontains(v, "\n")])
    error_message = "Tailscale settings must not contain double quotes or newlines (values are written as key=\"value\" lines into /etc/fck-nat.conf)."
  }
}

variable "pelotech_nat_tailscale_auth_key" {
  description = "Plain Tailscale auth key for NAT instances. Stored by the module in a SecureString SSM parameter (never written to user-data; the value does land in terraform state - prefer pelotech_nat.tailscale.auth_key_ssm with a pre-existing parameter)."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = !strcontains(var.pelotech_nat_tailscale_auth_key, "\"") && !strcontains(var.pelotech_nat_tailscale_auth_key, "\n")
    error_message = "Auth key must not contain double quotes or newlines."
  }
}

variable "existing_vpc" {
  type = object({
    vpc_id     = string
    subnet_ids = list(string)
  })
  default     = null
  description = "Use an existing VPC instead of creating one (null = create the VPC from the vpc variable)"
}

variable "vpc" {
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
  description = "Variables for defining the vpc for the stack (ignored when existing_vpc is set)"
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

variable "access" {
  description = "IAM role ARNs granted cluster access. admin_arns: cluster admins. admin_ro_arns: admin read only with secret and configmap access. ro_arns: read only. Both *_ro groups also get KMS readonly access for CI plan purposes; more limited access should use extra_access_entries."
  type = object({
    admin_arns    = optional(list(string), [])
    admin_ro_arns = optional(list(string), [])
    ro_arns       = optional(list(string), [])
  })
  default  = {}
  nullable = false
}

# --- Dedicated CNI node group (kube-ovn control plane) ---
# For CNIs whose control plane is pinned to specific master nodes (kube-ovn's
# ovn-central), a small dedicated node group hosts it so upgrades recycle it
# WITHOUT draining the initial/system group (coredns + critical addons stay up).
# Created by default only for cni = "kube-ovn".

variable "cni_node" {
  description = "Dedicated CNI node group (kube-ovn control plane). enabled: null derives from cni (true for kube-ovn, false otherwise); set false, apply, then true again to recycle it (e.g. for a version/AMI upgrade) without touching the initial group. kubernetes_version: version this group runs — bump to upgrade it; decoupled from cluster_version so a control-plane bump doesn't auto-roll it (null follows cluster_version, REQUIRED for cni=\"kube-ovn\"); replace it deliberately via the recycle (toggle enabled + bump cni-bootstrap's bootstrap_generation). instance_types: null falls back to initial_node.instance_types; must all be one architecture. ami_release_version: pin the AMI release (e.g. a same-version security patch); null uses the default AMI for its kubernetes_version. size: node count (min=max=desired); default 1 = a single kube-ovn ovn-central master."
  type = object({
    enabled             = optional(bool)
    kubernetes_version  = optional(string)
    instance_types      = optional(list(string))
    ami_release_version = optional(string)
    size                = optional(number, 1)
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.cni != "kube-ovn" || var.cni_node.kubernetes_version != null
    error_message = "cni_node.kubernetes_version must be set when cni = \"kube-ovn\" so a control-plane version bump does not auto-roll the CNI master node (kube-ovn deadlock). Set it to the current node k8s version, then bump it deliberately during a recycle."
  }
  validation {
    condition     = var.cni_node.instance_types == null || length(distinct([for t in var.cni_node.instance_types : can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", t))])) <= 1
    error_message = "All cni_node.instance_types must be the same architecture (all Graviton/arm64 or all x86_64)."
  }
}

variable "s3_csi" {
  description = "S3 CSI driver bucket access. create_bucket: create a new bucket for use with the driver. bucket_arns: existing buckets the driver should have access to."
  type = object({
    create_bucket = optional(bool, true)
    bucket_arns   = optional(list(string), [])
  })
  default  = {}
  nullable = false
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
