![pre-commit](https://github.com/pelotech/terraform-foundation-aws-stack/actions/workflows/pre-commit.yaml/badge.svg)

# Foundation - Pelotech's GitOps K8s Cluster
This is the terraform module that helps bootstrap foundation in AWS

This project uses [release-please](https://github.com/googleapis/release-please) for the release flow of contributions

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.7 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.45.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.100.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_cert_manager_irsa_role"></a> [cert\_manager\_irsa\_role](#module\_cert\_manager\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | 5.59.0 |
| <a name="module_ebs_csi_driver_irsa_role"></a> [ebs\_csi\_driver\_irsa\_role](#module\_ebs\_csi\_driver\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | 5.59.0 |
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | 20.37.2 |
| <a name="module_external_dns_irsa_role"></a> [external\_dns\_irsa\_role](#module\_external\_dns\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | 5.59.0 |
| <a name="module_fck_nat"></a> [fck\_nat](#module\_fck\_nat) | RaJiska/fck-nat/aws | 1.3.0 |
| <a name="module_karpenter"></a> [karpenter](#module\_karpenter) | terraform-aws-modules/eks/aws//modules/karpenter | 20.37.2 |
| <a name="module_load_balancer_controller_irsa_role"></a> [load\_balancer\_controller\_irsa\_role](#module\_load\_balancer\_controller\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | 5.59.0 |
| <a name="module_s3_csi"></a> [s3\_csi](#module\_s3\_csi) | terraform-aws-modules/s3-bucket/aws | 4.11.0 |
| <a name="module_s3_driver_irsa_role"></a> [s3\_driver\_irsa\_role](#module\_s3\_driver\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | 5.59.0 |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | 5.21.0 |

## Resources

| Name | Type |
|------|------|
| [aws_vpc_endpoint.eks_vpc_endpoints](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_eks_cluster_version"></a> [eks\_cluster\_version](#input\_eks\_cluster\_version) | Kubernetes version to set for the cluster | `string` | `"1.33"` | no |
| <a name="input_extra_access_entries"></a> [extra\_access\_entries](#input\_extra\_access\_entries) | EKS access entries needed by IAM roles interacting with this cluster | <pre>list(object({<br/>    principal_arn           = string<br/>    kubernetes_groups       = optional(list(string))<br/>    policy_associations     = optional(map(object({<br/>      policy_arn              = string<br/>      access_scope = object({<br/>        type = string<br/>        namespaces = optional(list(string))<br/>      })<br/>    })),{})<br/><br/>  }))</pre> | `[]` | no |
| <a name="input_initial_instance_types"></a> [initial\_instance\_types](#input\_initial\_instance\_types) | instance types of the initial managed node group | `list(string)` | n/a | yes |
| <a name="input_initial_node_desired_size"></a> [initial\_node\_desired\_size](#input\_initial\_node\_desired\_size) | desired size of the initial managed node group | `number` | `3` | no |
| <a name="input_initial_node_labels"></a> [initial\_node\_labels](#input\_initial\_node\_labels) | labels for the initial managed node group | `map(string)` | <pre>{<br/>  "kube-ovn/role": "master"<br/>}</pre> | no |
| <a name="input_initial_node_max_size"></a> [initial\_node\_max\_size](#input\_initial\_node\_max\_size) | max size of the initial managed node group | `number` | `6` | no |
| <a name="input_initial_node_min_size"></a> [initial\_node\_min\_size](#input\_initial\_node\_min\_size) | minimum size of the initial managed node group | `number` | `2` | no |
| <a name="input_initial_node_taints"></a> [initial\_node\_taints](#input\_initial\_node\_taints) | taints for the initial managed node group | `list(object({ key = string, value = string, effect = string }))` | <pre>[<br/>  {<br/>    "effect": "NO_SCHEDULE",<br/>    "key": "CriticalAddonsOnly",<br/>    "value": "true"<br/>  },<br/>  {<br/>    "effect": "NO_SCHEDULE",<br/>    "key": "nidhogg.uswitch.com/kube-system.kube-multus-ds",<br/>    "value": "true"<br/>  }<br/>]</pre> | no |
| <a name="input_s3_csi_driver_bucket_arns"></a> [s3\_csi\_driver\_bucket\_arns](#input\_s3\_csi\_driver\_bucket\_arns) | existing buckets the s3 CSI driver should have access to | `list(string)` | `[]` | no |
| <a name="input_s3_csi_driver_create_bucket"></a> [s3\_csi\_driver\_create\_bucket](#input\_s3\_csi\_driver\_create\_bucket) | create a new bucket for use with the s3 CSI driver | `bool` | `true` | no |
| <a name="input_stack_admin_arns"></a> [stack\_admin\_arns](#input\_stack\_admin\_arns) | arn to the roles for the cluster admins role | `list(string)` | `[]` | no |
| <a name="input_stack_create"></a> [stack\_create](#input\_stack\_create) | should resources be created | `bool` | `true` | no |
| <a name="input_stack_enable_cluster_kms"></a> [stack\_enable\_cluster\_kms](#input\_stack\_enable\_cluster\_kms) | Should secrets be encrypted by kms in the cluster | `bool` | `true` | no |
| <a name="input_stack_enable_default_eks_managed_node_group"></a> [stack\_enable\_default\_eks\_managed\_node\_group](#input\_stack\_enable\_default\_eks\_managed\_node\_group) | Ability to disable default node group | `bool` | `true` | no |
| <a name="input_stack_existing_vpc_config"></a> [stack\_existing\_vpc\_config](#input\_stack\_existing\_vpc\_config) | Setting the VPC | <pre>object({<br/>    vpc_id     = string<br/>    subnet_ids = list(string)<br/>  })</pre> | `null` | no |
| <a name="input_stack_fck_nat_enabled"></a> [stack\_fck\_nat\_enabled](#input\_stack\_fck\_nat\_enabled) | Use fck nat to save not managed nat cost | `bool` | `false` | no |
| <a name="input_stack_fck_nat_instance_type"></a> [stack\_fck\_nat\_instance\_type](#input\_stack\_fck\_nat\_instance\_type) | choose instance based on bandwitch requirements | `string` | `"t3.micro"` | no |
| <a name="input_stack_name"></a> [stack\_name](#input\_stack\_name) | Name of the stack | `string` | `"foundation-stack"` | no |
| <a name="input_stack_ro_arns"></a> [stack\_ro\_arns](#input\_stack\_ro\_arns) | arn to the roles for the cluster read only role, these will also have KMS readonly access for CI plan purposes, more limited access should use the extra entries | `list(string)` | `[]` | no |
| <a name="input_stack_tags"></a> [stack\_tags](#input\_stack\_tags) | tags to be added to the stack, should at least have Owner and Environment | `map(any)` | <pre>{<br/>  "Environment": "prod",<br/>  "Owner": "pelotech"<br/>}</pre> | no |
| <a name="input_stack_use_vpc_cni_max_pods"></a> [stack\_use\_vpc\_cni\_max\_pods](#input\_stack\_use\_vpc\_cni\_max\_pods) | Set to true if using the vpc cni - otherwise defaults to 110 max pods | `bool` | `false` | no |
| <a name="input_stack_vpc_block"></a> [stack\_vpc\_block](#input\_stack\_vpc\_block) | Variables for defining the vpc for the stack | <pre>object({<br/>    cidr             = string<br/>    azs              = list(string)<br/>    private_subnets  = list(string)<br/>    public_subnets   = list(string)<br/>    database_subnets = list(string)<br/>  })</pre> | <pre>{<br/>  "azs": [<br/>    "us-west-2a",<br/>    "us-west-2b",<br/>    "us-west-2c"<br/>  ],<br/>  "cidr": "172.16.0.0/16",<br/>  "database_subnets": [<br/>    "172.16.200.0/24",<br/>    "172.16.201.0/24",<br/>    "172.16.202.0/24"<br/>  ],<br/>  "private_subnets": [<br/>    "172.16.0.0/24",<br/>    "172.16.1.0/24",<br/>    "172.16.2.0/24"<br/>  ],<br/>  "public_subnets": [<br/>    "172.16.100.0/24",<br/>    "172.16.101.0/24",<br/>    "172.16.102.0/24"<br/>  ]<br/>}</pre> | no |
| <a name="input_vpc_endpoints"></a> [vpc\_endpoints](#input\_vpc\_endpoints) | vpc endpoints within the cluster vpc network, note: this only works when using the internal created VPC | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_eks_cluster_tls_certificate_sha1_fingerprint"></a> [eks\_cluster\_tls\_certificate\_sha1\_fingerprint](#output\_eks\_cluster\_tls\_certificate\_sha1\_fingerprint) | The SHA1 fingerprint of the public key of the cluster's certificate |
| <a name="output_eks_oidc_provider"></a> [eks\_oidc\_provider](#output\_eks\_oidc\_provider) | The OpenID Connect identity provider (issuer URL without leading `https://`) |
| <a name="output_eks_oidc_provider_arn"></a> [eks\_oidc\_provider\_arn](#output\_eks\_oidc\_provider\_arn) | EKS odic provider ARN to be able to add IRSA roles to the cluster out of band |
<!-- END_TF_DOCS -->
