################################################################################
# IRSA
################################################################################
output "eks_oidc_provider_arn" {
  description = "EKS odic provider ARN to be able to add IRSA roles to the cluster out of band"
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
  value = module.vpc
}
