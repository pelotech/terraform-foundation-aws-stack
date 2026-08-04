################################################################################
# IRSA
################################################################################
output "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN to be able to add IRSA roles to the cluster out of band. Null when no identity uses IRSA and irsa.create_oidc_provider is not forced true — the provider is not created."
  value       = module.eks.oidc_provider_arn
}

output "eks_oidc_provider" {
  description = "The OpenID Connect identity provider (issuer URL without leading `https://`). A property of the cluster itself, so this is populated whether or not the OIDC provider exists."
  value       = module.eks.oidc_provider
}

output "irsa_enabled_resolved" {
  description = "(introspection) Per-identity IRSA enablement after resolving create, irsa.enabled and irsa.overrides"
  value       = local.irsa_enabled
}

output "irsa_oidc_provider_enabled_resolved" {
  description = "(introspection) Whether the cluster's IAM OIDC provider is created, after resolving create, irsa.create_oidc_provider and per-identity IRSA usage"
  value       = local.irsa_oidc_provider_enabled
}
################################################################################
# VPC
################################################################################
output "vpc_id" {
  description = "ID of the VPC created by this module (null when existing_vpc is set)"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC created by this module (null when existing_vpc is set)"
  value       = module.vpc.vpc_cidr_block
}

output "vpc_azs" {
  description = "Availability zones requested for the module-created VPC. NOTE: this echoes vpc.azs and is populated even when existing_vpc is set."
  value       = module.vpc.azs
}

output "private_subnet_ids" {
  description = "IDs of the private subnets created by this module (empty when existing_vpc is set)"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "IDs of the public subnets created by this module (empty when existing_vpc is set)"
  value       = module.vpc.public_subnets
}

output "database_subnet_group" {
  description = "Name of the database subnet group created by this module (null when existing_vpc is set)"
  value       = module.vpc.database_subnet_group
}
################################################################################
# EKS Cluster
################################################################################
output "eks_cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "eks_cluster_iam_role_name" {
  description = "The name of the EKS cluster IAM role"
  value       = module.eks.cluster_iam_role_name
}

output "eks_cluster_endpoint" {
  description = "The endpoint for the EKS cluster API server"
  value       = module.eks.cluster_endpoint
}

output "cilium_k8s_service_host" {
  description = "Kubernetes API server host (no https:// scheme) for Cilium kubeProxyReplacement=true. Set helm k8sServiceHost to this and k8sServicePort to 443."
  # try(): cluster_endpoint is null when create = false, and replace() rejects a null argument.
  value = try(replace(module.eks.cluster_endpoint, "https://", ""), null)
}

output "eks_cluster_service_cidr" {
  description = "The cluster's Kubernetes service CIDR (AWS-assigned or configured). Wire into the cni-bootstrap module's service_cidr for kube-ovn (ipv4.SVC_CIDR)."
  value       = module.eks.cluster_service_cidr
}

output "region" {
  description = "The AWS region the stack is deployed in. Wire into the cni-bootstrap module's region so its node-registration poll can region-qualify the cluster."
  value       = data.aws_region.current.region
}

output "vpc_endpoints" {
  description = "Map of created VPC endpoints, keyed by service short-name. Values are the full aws_vpc_endpoint resource objects, not bare IDs — use e.g. vpc_endpoints[\"s3\"].id. Empty when vpc_endpoints is empty or existing_vpc is set."
  value       = try(module.vpc_endpoints[0].endpoints, {})
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for the cluster"
  value       = module.eks.cluster_certificate_authority_data
}

################################################################################
# Node Groups
################################################################################
output "eks_managed_node_groups" {
  description = "Map of attribute maps for all EKS managed node groups created"
  value       = module.eks.eks_managed_node_groups
}

output "eks_managed_node_groups_autoscaling_group_names" {
  description = "List of the autoscaling group names created by EKS managed node groups"
  value       = module.eks.eks_managed_node_groups_autoscaling_group_names
}

################################################################################
# Security Groups
################################################################################
output "cluster_security_group_id" {
  description = "Cluster security group that was created by Amazon EKS for the cluster"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "ID of the node shared security group"
  value       = module.eks.node_security_group_id
}

################################################################################
# KMS
################################################################################
output "kms_key_arn" {
  description = "The Amazon Resource Name (ARN) of the KMS key"
  value       = module.eks.kms_key_arn
}

################################################################################
# Karpenter
################################################################################
output "karpenter_node_iam_role_name" {
  description = "The name of the Karpenter node IAM role"
  value       = try(module.karpenter[0].node_iam_role_name, null)
}

output "karpenter_queue_name" {
  description = "The name of the Karpenter SQS queue"
  value       = try(module.karpenter[0].queue_name, null)
}

################################################################################
# Role ARNs — Pod Identity (the default mechanism)
#
# Null when Pod Identity is disabled for that identity. Karpenter has no entry here: it reuses its
# existing role for both mechanisms, so karpenter_role_arn below covers it.
################################################################################
output "load_balancer_controller_role_arn" {
  description = "ARN of the ALB controller Pod Identity role"
  value       = try(module.load_balancer_controller_pod_identity[0].iam_role_arn, null)
}

output "ebs_csi_driver_role_arn" {
  description = "ARN of the EBS CSI driver Pod Identity role"
  value       = try(module.ebs_csi_driver_pod_identity[0].iam_role_arn, null)
}

output "s3_csi_driver_role_arn" {
  description = "ARN of the S3 CSI driver Pod Identity role"
  value       = try(module.s3_csi_driver_pod_identity[0].iam_role_arn, null)
}

output "external_dns_role_arn" {
  description = "ARN of the External DNS Pod Identity role"
  value       = try(module.external_dns_pod_identity[0].iam_role_arn, null)
}

output "cert_manager_role_arn" {
  description = "ARN of the Cert Manager Pod Identity role"
  value       = try(module.cert_manager_pod_identity[0].iam_role_arn, null)
}

output "karpenter_role_arn" {
  description = "ARN of the Karpenter controller role. One role serves both mechanisms, so this is correct whether Karpenter uses Pod Identity or IRSA."
  value       = try(module.karpenter[0].iam_role_arn, null)
}

################################################################################
# Role ARNs — IRSA
#
# Not deprecated. Pod Identity cannot serve Fargate (its agent is a DaemonSet), so IRSA stays a
# supported mechanism and these roles are permanent. v10.0.0 flips the irsa.enabled default to
# false, making IRSA opt-in; nothing here is removed.
################################################################################
output "load_balancer_controller_irsa_role_arn" {
  description = "ARN of the ALB controller IRSA role. Null when load_balancer_controller is not on IRSA."
  value       = try(module.load_balancer_controller_irsa_role[0].arn, null)
}

output "ebs_csi_driver_irsa_role_arn" {
  description = "ARN of the EBS CSI driver IRSA role. Null when ebs_csi_driver is not on IRSA."
  value       = try(module.ebs_csi_driver_irsa_role[0].arn, null)
}

output "s3_csi_driver_irsa_role_arn" {
  description = "ARN of the S3 CSI driver IRSA role. Null when s3_csi_driver is not on IRSA."
  value       = try(module.s3_driver_irsa_role[0].arn, null)
}

output "external_dns_irsa_role_arn" {
  description = "ARN of the External DNS IRSA role. Null when external_dns is not on IRSA."
  value       = try(module.external_dns_irsa_role[0].arn, null)
}

output "cert_manager_irsa_role_arn" {
  description = "ARN of the Cert Manager IRSA role. Null when cert_manager is not on IRSA."
  value       = try(module.cert_manager_irsa_role[0].arn, null)
}

output "s3_csi_policy_attached_resolved" {
  description = "(introspection) Whether the Mountpoint S3 policy is attached to the S3 CSI roles. False when no bucket is created and no bucket_arns are supplied, which avoids the upstream fallback that would otherwise grant s3:ListBucket on every bucket in the account."
  value       = local.attach_s3_csi_policy
}

output "pod_identity_hosted_zone_arns_resolved" {
  description = "(introspection) Route53 hosted zone ARNs scoped onto the cert-manager and external-dns Pod Identity roles"
  value       = local.pod_identity_hosted_zone_arns
}

output "pod_identity_enabled_resolved" {
  description = "(introspection) Per-identity Pod Identity enablement after resolving create, pod_identity.enabled and pod_identity.overrides"
  value       = local.pod_identity_enabled
}

output "pod_identity_associations_resolved" {
  description = "(introspection) Namespace/service-account pairs each enabled identity is associated with, including any cross-account target_role_arn"
  value = {
    for k, v in local.workload_identities : k => {
      namespace       = v.namespace
      service_account = v.service_account
      target_role_arn = local.pod_identity_target_role_arns[k]
    } if local.pod_identity_enabled[k]
  }
}

################################################################################
# CNI profile (resolved)
################################################################################
output "initial_node_taints_resolved" {
  description = "(introspection) Taints applied to the initial managed node group after resolving cni and initial_node.taints(_extra)"
  value       = local.initial_taints
}

output "initial_node_labels_resolved" {
  description = "(introspection) Labels applied to the initial managed node group after resolving cni and initial_node.labels(_extra)"
  value       = local.initial_labels
}

output "cluster_addons_enabled_resolved" {
  description = "(introspection) Managed addon enablement after resolving cni and the addons.* overrides"
  value       = local.cluster_addons_enabled
}

output "cni_node_group_enabled" {
  description = "(introspection) Whether the dedicated CNI node group is created (true for kube-ovn unless disabled)."
  value       = local.enable_cni_node_group
}

output "coredns_tolerations_resolved" {
  description = "(introspection) Tolerations added to the coredns addon beyond its own defaults, resolved from the cni profile. Empty means the addon's stock tolerations apply (which already cover CriticalAddonsOnly)."
  value       = local.coredns_tolerations
}

output "cni_node_size" {
  description = "Size of the dedicated CNI node group. Wire this into the cni-bootstrap module's wait_for_nodes_count — if the two disagree the bootstrap poll hangs until wait_for_nodes_timeout and fails the apply. 0 when no CNI node group is created."
  value       = local.enable_cni_node_group ? var.cni_node.size : 0
}

output "cni_node_taints_resolved" {
  description = "(introspection) Taints the cni profile defines for the dedicated CNI node group. Derived from the profile alone, so this stays populated even when the group is not created (e.g. cni_node.enabled = false) — use cni_node_group_enabled to test for the group's existence."
  value       = local.cni_node_taints
}

output "cni_node_labels_resolved" {
  description = "(introspection) Labels the cni profile defines for the dedicated CNI node group. Derived from the profile alone, so this stays populated even when the group is not created (e.g. cni_node.enabled = false) — use cni_node_group_enabled to test for the group's existence."
  value       = local.cni_node_labels
}

output "nat_tailscale_conf_resolved" {
  description = "(introspection) Rendered tailscale fck-nat.conf lines per AZ ({} when tailscale is disabled). Only references the SSM parameter name, never the key value."
  value       = local.nat_tailscale_conf_by_az
}
