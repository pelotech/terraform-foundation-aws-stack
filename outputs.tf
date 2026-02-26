################################################################################
# IRSA
################################################################################
output "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN to be able to add IRSA roles to the cluster out of band"
  value       = module.eks.oidc_provider_arn
}

output "eks_oidc_provider" {
  description = "The OpenID Connect identity provider (issuer URL without leading `https://`)"
  value       = module.eks.oidc_provider
}

output "eks_cluster_tls_certificate_sha1_fingerprint" {
  description = "The SHA1 fingerprint of the public key of the cluster's certificate"
  value       = module.eks.cluster_tls_certificate_sha1_fingerprint
}
################################################################################
# VPC
################################################################################
output "vpc" {
  description = "The vpc object when it's created"
  value       = module.vpc
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
# IRSA Role ARNs
################################################################################
output "load_balancer_controller_role_arn" {
  description = "ARN of the ALB controller IRSA role"
  value       = module.load_balancer_controller_irsa_role.arn
}

output "ebs_csi_driver_role_arn" {
  description = "ARN of the EBS CSI driver IRSA role"
  value       = module.ebs_csi_driver_irsa_role.arn
}

output "s3_csi_driver_role_arn" {
  description = "ARN of the S3 CSI driver IRSA role"
  value       = try(module.s3_driver_irsa_role[0].arn, null)
}

output "external_dns_role_arn" {
  description = "ARN of the External DNS IRSA role"
  value       = try(module.external_dns_irsa_role[0].arn, null)
}

output "cert_manager_role_arn" {
  description = "ARN of the Cert Manager IRSA role"
  value       = try(module.cert_manager_irsa_role[0].arn, null)
}

output "karpenter_role_arn" {
  description = "ARN of the Karpenter IRSA role"
  value       = try(module.karpenter[0].iam_role_arn, null)
}
