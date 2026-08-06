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
  validation {
    condition     = var.initial_node.min_size <= var.initial_node.desired_size && var.initial_node.desired_size <= var.initial_node.max_size
    error_message = "initial_node sizes must satisfy: min_size <= desired_size <= max_size."
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
  description = "Create the EKS cluster and its IAM identities (cluster, node groups, addons, Karpenter, IRSA and Pod Identity roles). NOTE: this does NOT gate the surrounding infrastructure — the VPC, subnets, NAT instances, EIPs, Tailscale SSM parameters, VPC endpoints and the S3 CSI bucket are created regardless, gated by their own variables (existing_vpc, pelotech_nat, vpc_endpoints, s3_csi). Setting create = false plans successfully but still bills for those."
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
  description = "Managed cluster addon toggles and overrides. vpc_cni/kube_proxy: leave null (default) to derive from the cni profile (vpc-cni: on for cni=vpc-cni; kube-proxy: off for cilium kube-proxy replacement); set true/false to force. When the vpc-cni addon is off, nodeadm maxPods=110 cloudinit is applied automatically. pod_identity_agent: leave null (default) to enable whenever any identity uses Pod Identity; set true/false to force. The agent is what actually vends credentials, so forcing it false while pod_identity is enabled creates associations with nothing to serve them — the apply still succeeds and the associations look correct, but pods silently get no credentials. Only force false if you run the agent yourself (e.g. a self-managed DaemonSet). Force true if you create pod identity associations out of band while pod_identity is disabled here. overrides: per-addon overrides keyed by addon name (e.g. \"vpc-cni\", \"kube-proxy\", \"coredns\", \"eks-pod-identity-agent\") merged over module defaults — accepts any attributes supported by terraform-aws-modules/eks/aws v21+ `addons` map."
  type = object({
    vpc_cni            = optional(bool)
    kube_proxy         = optional(bool)
    coredns            = optional(bool, true)
    pod_identity_agent = optional(bool)
    overrides          = optional(any, {})
  })
  default  = {}
  nullable = false
}

variable "irsa" {
  description = <<-EOT
    IRSA (IAM Roles for Service Accounts) for the workload identities this module creates
    (load_balancer_controller, ebs_csi_driver, s3_csi_driver, external_dns, cert_manager, karpenter).

    Resolves per identity exactly like `pod_identity`: the override wins, otherwise `enabled`. The
    two mechanisms are independent, so each identity is on IRSA, on Pod Identity, on both (the
    default, which makes a cutover reversible without an IAM change), or on neither.

    Mixing matters because the eks-pod-identity-agent is a DaemonSet and does not run on Fargate: a
    controller scheduled onto Fargate has to stay on IRSA while the rest of the cluster moves, so
    `enabled = false` with an override re-enabling that one identity is the expected shape.

    Leaving an identity on neither mechanism is allowed — use it when you manage that role out of
    band — but this module then creates no role for it, and nothing warns you at plan time.

    enabled              — v10.0.0 flips this default to false, making IRSA opt-in. The roles and
                           the *_irsa_role_arn outputs are permanent; only the default changes.
    create_oidc_provider — null (default) creates the cluster's IAM OIDC provider whenever any
                           identity resolves to IRSA. Set true to keep it after the last identity
                           has moved, for out-of-band roles that federate against it. The issuer URL
                           (eks_oidc_provider) belongs to the cluster and survives either way.

    Karpenter has one role trusting both mechanisms rather than a role per mechanism, so it behaves
    differently at the edges — see README, "Choosing a mechanism".
  EOT
  type = object({
    enabled              = optional(bool, true)
    create_oidc_provider = optional(bool)
    overrides = optional(map(object({
      enabled = optional(bool)
    })), {})
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k in keys(var.irsa.overrides) : contains([
        "load_balancer_controller",
        "ebs_csi_driver",
        "s3_csi_driver",
        "external_dns",
        "cert_manager",
        "karpenter",
      ], k)
    ])
    error_message = "irsa.overrides keys must be one of: load_balancer_controller, ebs_csi_driver, s3_csi_driver, external_dns, cert_manager, karpenter."
  }

  validation {
    # Every IRSA role, and karpenter's web-identity trust statement, interpolates the provider ARN.
    # Without this the plan fails deep inside the upstream module with "provider_arn is null".
    # Deliberately stricter than local.irsa_enabled: enabled = true with all six identities
    # overridden off is rejected rather than picked apart. Write enabled = false instead.
    condition = coalesce(var.irsa.create_oidc_provider, true) || (
      !var.irsa.enabled &&
      !anytrue([for v in var.irsa.overrides : coalesce(v.enabled, false)])
    )
    error_message = "irsa.create_oidc_provider = false requires irsa.enabled = false and no override re-enabling an identity: the IRSA roles federate against the provider being suppressed. Leave create_oidc_provider null to let it follow usage instead."
  }
}

variable "pod_identity" {
  description = <<-EOT
    EKS Pod Identity for the workload identities this module creates (load_balancer_controller,
    ebs_csi_driver, s3_csi_driver, external_dns, cert_manager, karpenter).

    When enabled, each identity gets its own Pod Identity role plus an association, and the
    `eks-pod-identity-agent` addon is installed. The IRSA roles are left untouched and keep their
    own ARNs, so disabling an identity is a no-op on existing state.

    NOTE: Pod Identity takes precedence over an `eks.amazonaws.com/role-arn` service account
    annotation. Disable an identity here to keep IRSA serving it.

    overrides (keyed by identity name):
      enabled              — false leaves the identity to `irsa`, which may itself be off for it
                             (required in GovCloud for cert_manager/external_dns when the hosted
                             zones live in a commercial account, since IAM cannot assume a role
                             across partitions).
      target_role_arn      — cross-account role chaining. The target role holds the permissions,
                             so the predefined policy is replaced by an sts:AssumeRole grant.
                             Same-partition only; not supported for karpenter.
      disable_session_tags — passed through to the association. Not supported for karpenter.
      hosted_zone_arns     — Route53 scoping for cert_manager/external_dns only. Null (default)
                             keeps the historic unscoped grant. Applies to the Pod Identity role
                             only: an identity left on IRSA keeps its own unscoped grant, because
                             the IRSA roles are deliberately never modified.
  EOT
  type = object({
    enabled = optional(bool, true)
    overrides = optional(map(object({
      enabled              = optional(bool)
      target_role_arn      = optional(string)
      disable_session_tags = optional(bool)
      hosted_zone_arns     = optional(list(string))
    })), {})
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k in keys(var.pod_identity.overrides) : contains([
        "load_balancer_controller",
        "ebs_csi_driver",
        "s3_csi_driver",
        "external_dns",
        "cert_manager",
        "karpenter",
      ], k)
    ])
    error_message = "pod_identity.overrides keys must be one of: load_balancer_controller, ebs_csi_driver, s3_csi_driver, external_dns, cert_manager, karpenter."
  }

  validation {
    condition = alltrue([
      for k, v in var.pod_identity.overrides :
      v.target_role_arn == null || coalesce(v.enabled, var.pod_identity.enabled)
    ])
    error_message = "pod_identity.overrides[*].target_role_arn requires Pod Identity to be enabled for that identity."
  }

  validation {
    condition = (
      try(var.pod_identity.overrides["karpenter"].target_role_arn, null) == null &&
      try(var.pod_identity.overrides["karpenter"].disable_session_tags, null) == null
    )
    error_message = "pod_identity.overrides.karpenter supports only `enabled`; its association is owned by the upstream karpenter submodule."
  }

  validation {
    condition = alltrue([
      for k, v in var.pod_identity.overrides :
      v.hosted_zone_arns == null || contains(["cert_manager", "external_dns"], k)
    ])
    error_message = "pod_identity.overrides[*].hosted_zone_arns is only supported for cert_manager and external_dns."
  }

  validation {
    # An empty list renders an IAM statement with no Resource, which IAM rejects at apply time.
    # Omit the attribute to keep the unscoped grant instead.
    condition = alltrue([
      for k, v in var.pod_identity.overrides :
      v.hosted_zone_arns == null || length(coalesce(v.hosted_zone_arns, [])) > 0
    ])
    error_message = "pod_identity.overrides[*].hosted_zone_arns must not be an empty list; omit it to keep the unscoped grant."
  }
}

variable "create_cluster_kms" {
  type        = bool
  default     = true
  description = "Should secrets be encrypted by kms in the cluster"
}

variable "pelotech_nat" {
  description = "Pelotech NAT instances replacing the managed NAT gateway — a hardened fck-nat-based image (FIPS, L2 compliance, optional Tailscale) from AWS Marketplace. IMPORTANT: the default AMI is the Pelotech NAT image from AWS Marketplace and requires an active Marketplace subscription in the target account — without one the instance launch fails at apply time with OptInRequired. Subscribe first, or point ami_owner_id/ami_name_filter at your own image. create_eip creates the NAT EIP even when enabled=false — nice for getting ips created for allow lists. auto_rollout (default false): when enabled, a newer AMI matching ami_name_filter found at apply time triggers a rolling instance refresh on the NAT ASG (brief per-AZ NAT outage while the instance is replaced); leave false to recycle instances manually. tailscale: provide auth via tailscale.auth_key_ssm (name of an existing SSM parameter) or pelotech_nat_tailscale_auth_key (plain key; the module stores it in a SecureString SSM parameter it creates). The instances always read the key from SSM. SecureString params under the default aws/ssm KMS key work as-is; customer-managed KMS keys on an existing parameter require a key-policy grant outside this module."
  type = object({
    enabled         = optional(bool, false)
    instance_type   = optional(string, "t4g.micro")
    ami_owner_id    = optional(string, "aws-marketplace")
    ami_name_filter = optional(string, "pelotech-nat-al2023-hvm-*")
    create_eip      = optional(bool, false)
    auto_rollout    = optional(bool, false)
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
  validation {
    # With existing_vpc the module-created subnet/route-table outputs are empty while module.vpc.azs
    # still returns var.vpc.azs, so the count is non-zero and indexing fails.
    condition     = !var.pelotech_nat.enabled || var.existing_vpc == null
    error_message = "pelotech_nat.enabled cannot be combined with existing_vpc: the module can only place NAT instances in subnets and route tables it created. Manage NAT yourself in a pre-existing VPC."
  }
  validation {
    condition     = !var.pelotech_nat.create_eip || var.existing_vpc == null
    error_message = "pelotech_nat.create_eip cannot be combined with existing_vpc: the EIP count is derived from the module-created VPC's availability zones."
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

  validation {
    # NAT instances and per-AZ resources index the subnet lists by AZ position.
    condition     = length(var.vpc.azs) <= length(var.vpc.public_subnets)
    error_message = "vpc.public_subnets must have at least as many entries as vpc.azs; per-AZ resources index it by AZ position."
  }
  validation {
    condition     = length(var.vpc.azs) <= length(var.vpc.private_subnets)
    error_message = "vpc.private_subnets must have at least as many entries as vpc.azs; per-AZ resources index it by AZ position."
  }
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
    # coalesce rather than a `== null ||` guard — see the note on cni_node.instance_types below.
    condition = alltrue([
      for entry in var.extra_access_entries : alltrue([
        for policy in values(coalesce(entry.policy_associations, {})) : contains(["namespace", "cluster"], policy.access_scope.type)
      ])
    ])
  }

  validation {
    error_message = "The access scope type 'namespace' requires 'namespaces', namespaces can't be set otherwise."
    condition = alltrue([
      for entry in var.extra_access_entries : alltrue([
        for policy in values(coalesce(entry.policy_associations, {})) : ((policy.access_scope.type == "namespace" && policy.access_scope.namespaces != null) || policy.access_scope.type == "cluster" && policy.access_scope.namespaces == null)
      ])
    ])
  }
}

variable "access" {
  description = "IAM role ARNs granted cluster access. admin_arns: cluster admins. admin_ro_arns: admin read only with secret and configmap access. ro_arns: read only. KMS: admin_arns AND admin_ro_arns are both granted KMS key *administrator* on the cluster secrets key — that includes kms:PutKeyPolicy and kms:ScheduleKeyDeletion, so admin_ro_arns is not read-only with respect to KMS and can self-escalate or schedule the key for deletion. ro_arns receives no KMS access at all. For genuinely least-privilege access, use extra_access_entries instead of admin_ro_arns."
  type = object({
    admin_arns    = optional(list(string), [])
    admin_ro_arns = optional(list(string), [])
    ro_arns       = optional(list(string), [])
  })
  default  = {}
  nullable = false
}

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
    # coalesce, not `== null ||`: Terraform 1.9 does not short-circuit ||, so the for expression
    # still evaluates and fails with "Iteration over null value" when instance_types is unset.
    condition     = length(distinct([for t in coalesce(var.cni_node.instance_types, []) : can(regex("[a-zA-Z]+\\d+g[a-z]*\\..+", t))])) <= 1
    error_message = "All cni_node.instance_types must be the same architecture (all Graviton/arm64 or all x86_64)."
  }
  validation {
    condition     = var.cni_node.instance_types == null || length(coalesce(var.cni_node.instance_types, [])) > 0
    error_message = "cni_node.instance_types must not be empty; omit it to inherit initial_node.instance_types."
  }
  validation {
    condition     = var.cni_node.size >= 1
    error_message = "cni_node.size must be >= 1."
  }
}

variable "s3_csi" {
  description = "S3 CSI driver bucket access. create_bucket: create a new bucket for use with the driver. bucket_name: override the generated bucket name (default \"<tags.Owner>-<name>-csi-bucket\"); required if tags has no Owner key. bucket_arns: existing buckets the driver should have access to. When create_bucket is false and bucket_arns is empty, no S3 policy is attached to the driver roles at all."
  type = object({
    create_bucket = optional(bool, true)
    bucket_name   = optional(string)
    bucket_arns   = optional(list(string), [])
  })
  default  = {}
  nullable = false

  validation {
    # The generated name interpolates the free-form var.tags["Owner"]: a missing key crashes the
    # plan, and an uppercase/spaced/long value fails at apply. bucket_name is the escape hatch.
    condition     = var.s3_csi.bucket_name != null || contains(keys(var.tags), "Owner")
    error_message = "s3_csi bucket naming requires either s3_csi.bucket_name, or an \"Owner\" key in var.tags. The generated name is \"<tags.Owner>-<name>-csi-bucket\" and must be a valid S3 bucket name: lowercase, [a-z0-9.-], 3-63 characters."
  }
  validation {
    condition     = var.s3_csi.bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.s3_csi.bucket_name))
    error_message = "s3_csi.bucket_name must be a valid S3 bucket name: lowercase, [a-z0-9.-], 3-63 characters, starting and ending alphanumeric."
  }
}

variable "vpc_endpoints" {
  type        = list(string)
  description = <<-EOT
    VPC endpoint service short-names to create (empty = none). Interface endpoints let private nodes
    reach ECR/STS/SSM/EC2 and be SSM-debuggable without NAT egress; kubelet->API already works
    privately via the cluster's endpoint_private_access ENIs. Internal (module-created) VPC only.

    COST: s3 and dynamodb are free Gateway endpoints. Every other name is an Interface endpoint at
    ~$7/mo per AZ (about $22/mo per service across 3 AZs) plus data processing.

    Recommended set for private/NAT-resilient clusters:
    ["s3", "ssm", "ssmmessages", "ec2messages", "ec2", "ecr.api", "ecr.dkr", "sts",
     "elasticloadbalancing", "autoscaling"]
  EOT
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
