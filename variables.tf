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
variable "eks_cluster_version" {
  type        = string
  default     = "1.35"
  description = "Kubernetes version to set for the cluster"
}
variable "stack_tags" {
  type = map(any)
  default = {
    Owner       = "pelotech"
    Environment = "prod"
  }
  description = "tags to be added to the stack, should at least have Owner and Environment"
}
variable "stack_use_vpc_cni_max_pods" {
  type        = bool
  default     = false
  description = "Set to true if using the vpc cni - otherwise defaults to 110 max pods"
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
  type = map(object({ key = string, value = string, effect = string }))
  default = {
    criticalAddonsOnly = {
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
    nidhogg = {
      key    = "nidhogg.uswitch.com/kube-system.kube-multus-ds"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }
  description = "taints for the initial managed node group"
}
variable "initial_node_labels" {
  type = map(string)
  default = {
    "kube-ovn/role" = "master"
  }
  description = "labels for the initial managed node group"
}

variable "initial_instance_types" {
  type        = list(string)
  description = "instance types of the initial managed node group"
}

variable "initial_node_min_size" {
  type        = number
  default     = 2
  description = "minimum size of the initial managed node group"
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
  type        = list(string)
  description = "vpc endpoints within the cluster vpc network, note: this only works when using the internal created VPC"
  default     = []
}
