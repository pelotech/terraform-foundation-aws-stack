![pre-commit](https://github.com/pelotech/terraform-foundation-aws-stack/actions/workflows/pre-commit.yaml/badge.svg)

# Foundation - Pelotech's GitOps K8s Cluster
This is the terraform module that helps bootstrap foundation in AWS

This project uses [release-please](https://github.com/googleapis/release-please) for the release flow of contributions

## Upgrading to v7.0.0 (breaking changes)

This release puts the three core EKS addons under Terraform management via
the EKS managed-addons API, with per-addon enable toggles. **vpc-cni is now
opt-in** (`stack_enable_vpc_cni_addon` defaults to `false`); kube-proxy and
coredns default to `true`. `stack_use_vpc_cni_max_pods` is removed.

### What happens on first apply against an existing cluster

| Addon       | Default | Plan effect on an existing v6.x cluster                                                              |
| ----------- | ------- | ---------------------------------------------------------------------------------------------------- |
| vpc-cni     | `false` | **Nothing.** Existing self-managed `aws-node` DaemonSet is left untouched and remains unmanaged.     |
| kube-proxy  | `true`  | `+ create` managed addon. `OVERWRITE` adopts the existing self-managed DaemonSet. No disruption.     |
| coredns     | `true`  | `+ create` managed addon. `OVERWRITE` adopts the existing self-managed Deployment. No disruption.    |

If you want to keep vpc-cni under Terraform, set
`stack_enable_vpc_cni_addon = true` explicitly — the same OVERWRITE
adoption applies (no pod restarts).

### `stack_use_vpc_cni_max_pods` is removed

`stack_enable_vpc_cni_addon` now drives both addon install *and* the
nodeadm `maxPods=110` cloudinit:

| Old setting                                     | New equivalent                                 | Behavior                                                                                |
| ----------------------------------------------- | ---------------------------------------------- | --------------------------------------------------------------------------------------- |
| `stack_use_vpc_cni_max_pods = false` (default)  | `stack_enable_vpc_cni_addon = false` (default) | No managed vpc-cni; **nodes get `maxPods=110` cloudinit** so an alternative CNI fits.   |
| `stack_use_vpc_cni_max_pods = true`             | `stack_enable_vpc_cni_addon = true`            | vpc-cni installed/adopted as managed addon; no maxPods cloudinit (ENI math drives pod density). |

> **Heads-up for users running self-managed vpc-cni today:** with the new
> default (`false`), the next node refresh will apply `maxPods=110`
> cloudinit even though `aws-node` is still running on your nodes. To
> preserve the prior pod-density behavior, set
> `stack_enable_vpc_cni_addon = true` so the module manages vpc-cni and
> skips the cloudinit cap.

### Removing vpc-cni from an existing cluster (CNI swap)

Because Terraform never managed your existing `aws-node` DaemonSet, simply
leaving `stack_enable_vpc_cni_addon` at its default `false` will not
remove it. Two paths:

1. **Two-step (recommended):** set `stack_enable_vpc_cni_addon = true`,
   apply (AWS adopts the DaemonSet via `OVERWRITE`); then set it back to
   `false`, apply (managed addon is destroyed and `preserve = false`
   removes the DaemonSet too).
2. **Manual:** leave the variable at `false` and run
   `kubectl delete daemonset -n kube-system aws-node` once your
   replacement CNI is healthy.

### Switching to an alternative CNI (Cilium, Kube-OVN)

The default behavior already supports this: keep
`stack_enable_vpc_cni_addon = false`, install your CNI out-of-band (Helm,
ArgoCD) using the existing outputs (`eks_cluster_endpoint`,
`eks_cluster_certificate_authority_data`, `eks_oidc_provider_arn`,
`cluster_security_group_id`, `node_security_group_id`, `vpc`). The
`maxPods=110` nodeadm cloudinit is applied automatically.

> **Removal is destructive by design.** Disabling any managed addon
> (`stack_enable_vpc_cni_addon`, `stack_enable_kube_proxy_addon`,
> `stack_enable_coredns_addon`) after it has been adopted tells AWS to
> remove **both** the addon registration and its underlying workload
> (`aws-node` / `kube-proxy` / `coredns`) — the module sets
> `preserve = false` so a CNI swap leaves a clean slate. For phased
> migrations where you want the workload to keep running after
> deregistration, set `preserve = true` per-addon via
> `stack_cluster_addons_overrides` (see "Power-user overrides" below).

## CNI selection

| CNI       | `stack_enable_vpc_cni_addon` | `stack_enable_kube_proxy_addon` | Notes                                                            |
| --------- | ---------------------------- | ------------------------------- | ---------------------------------------------------------------- |
| vpc-cni   | `true`                       | `true` (default)                | AWS native. IRSA / prefix delegation via `*_overrides`.          |
| Cilium    | `false` (default)            | `false` for kube-proxy-replace  | Install via Helm post-bootstrap. See Cilium docs for EKS.        |
| Kube-OVN  | `false` (default)            | `true` (default)                | Install via Helm/ArgoCD post-bootstrap.                          |
| Other     | `false` (default)            | varies                          | Anything that wants a clean slate works the same way.            |

### Example: Cilium with kube-proxy replacement

```hcl
module "foundation" {
  # ...
  stack_enable_vpc_cni_addon    = false
  stack_enable_kube_proxy_addon = false
  stack_enable_coredns_addon    = true
}
```

Then install Cilium with `kubeProxyReplacement=true` per the
[Cilium EKS install guide](https://docs.cilium.io/en/stable/installation/k8s-install-helm/).

### Example: Kube-OVN

```hcl
module "foundation" {
  # ...
  stack_enable_vpc_cni_addon = false
  # kube-proxy and coredns stay enabled
}
```

Install Kube-OVN per the
[upstream install docs](https://kubeovn.github.io/docs/stable/en/start/one-step-install/).

### Power-user overrides

Pin addon versions or pass addon-specific configuration (e.g. vpc-cni prefix
delegation) via `stack_cluster_addons_overrides`:

```hcl
stack_cluster_addons_overrides = {
  "vpc-cni" = {
    configuration_values = jsonencode({
      env = { ENABLE_PREFIX_DELEGATION = "true" }
    })
    # Keep the aws-node DaemonSet running after disabling the managed addon
    # (e.g. for a phased CNI migration). Default is preserve = false.
    preserve = true
  }
  "coredns" = {
    addon_version = "v1.11.4-eksbuild.2"
    most_recent   = false
  }
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.7 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.14.1 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.42.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_cert_manager_irsa_role"></a> [cert\_manager\_irsa\_role](#module\_cert\_manager\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.6.0 |
| <a name="module_ebs_csi_driver_irsa_role"></a> [ebs\_csi\_driver\_irsa\_role](#module\_ebs\_csi\_driver\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.6.0 |
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | 21.19.0 |
| <a name="module_external_dns_irsa_role"></a> [external\_dns\_irsa\_role](#module\_external\_dns\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.6.0 |
| <a name="module_fck_nat"></a> [fck\_nat](#module\_fck\_nat) | RaJiska/fck-nat/aws | 1.4.0 |
| <a name="module_karpenter"></a> [karpenter](#module\_karpenter) | terraform-aws-modules/eks/aws//modules/karpenter | 21.19.0 |
| <a name="module_load_balancer_controller_irsa_role"></a> [load\_balancer\_controller\_irsa\_role](#module\_load\_balancer\_controller\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.6.0 |
| <a name="module_s3_csi"></a> [s3\_csi](#module\_s3\_csi) | terraform-aws-modules/s3-bucket/aws | 5.12.0 |
| <a name="module_s3_driver_irsa_role"></a> [s3\_driver\_irsa\_role](#module\_s3\_driver\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.6.0 |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | 6.6.1 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eip.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_vpc_endpoint.eks_vpc_endpoints](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_ami.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.source](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_initial_instance_types"></a> [initial\_instance\_types](#input\_initial\_instance\_types) | instance types of the initial managed node group | `list(string)` | n/a | yes |
| <a name="input_cluster_enabled_log_types"></a> [cluster\_enabled\_log\_types](#input\_cluster\_enabled\_log\_types) | List of EKS control plane log types to enable. Valid values: api, audit, authenticator, controllerManager, scheduler. | `list(string)` | `[]` | no |
| <a name="input_cluster_endpoint_public_access"></a> [cluster\_endpoint\_public\_access](#input\_cluster\_endpoint\_public\_access) | Whether the EKS cluster API server endpoint is publicly accessible. Set to false for private-only access (requires VPC connectivity). | `bool` | `true` | no |
| <a name="input_create_node_security_group"></a> [create\_node\_security\_group](#input\_create\_node\_security\_group) | Whether to create a dedicated security group for EKS managed node groups. When true, the node\_security\_group\_id output is populated. | `bool` | `false` | no |
| <a name="input_eks_cluster_version"></a> [eks\_cluster\_version](#input\_eks\_cluster\_version) | Kubernetes version to set for the cluster | `string` | `"1.35"` | no |
| <a name="input_extra_access_entries"></a> [extra\_access\_entries](#input\_extra\_access\_entries) | EKS access entries needed by IAM roles interacting with this cluster | <pre>list(object({<br/>    principal_arn     = string<br/>    kubernetes_groups = optional(list(string))<br/>    policy_associations = optional(map(object({<br/>      policy_arn = string<br/>      access_scope = object({<br/>        type       = string<br/>        namespaces = optional(list(string))<br/>      })<br/>    })), {})<br/><br/>  }))</pre> | `[]` | no |
| <a name="input_initial_node_desired_size"></a> [initial\_node\_desired\_size](#input\_initial\_node\_desired\_size) | desired size of the initial managed node group | `number` | `3` | no |
| <a name="input_initial_node_labels"></a> [initial\_node\_labels](#input\_initial\_node\_labels) | labels for the initial managed node group | `map(string)` | <pre>{<br/>  "kube-ovn/role": "master"<br/>}</pre> | no |
| <a name="input_initial_node_max_size"></a> [initial\_node\_max\_size](#input\_initial\_node\_max\_size) | max size of the initial managed node group | `number` | `6` | no |
| <a name="input_initial_node_min_size"></a> [initial\_node\_min\_size](#input\_initial\_node\_min\_size) | minimum size of the initial managed node group | `number` | `2` | no |
| <a name="input_initial_node_taints"></a> [initial\_node\_taints](#input\_initial\_node\_taints) | taints for the initial managed node group | `map(object({ key = string, value = string, effect = string }))` | <pre>{<br/>  "criticalAddonsOnly": {<br/>    "effect": "NO_SCHEDULE",<br/>    "key": "CriticalAddonsOnly",<br/>    "value": "true"<br/>  },<br/>  "nidhogg": {<br/>    "effect": "NO_SCHEDULE",<br/>    "key": "nidhogg.uswitch.com/kube-system.kube-multus-ds",<br/>    "value": "true"<br/>  }<br/>}</pre> | no |
| <a name="input_permissions_boundary"></a> [permissions\_boundary](#input\_permissions\_boundary) | IAM permissions boundary policy name applied to all IAM roles. When set, constructs full ARN from the current account and partition. | `string` | `""` | no |
| <a name="input_s3_csi_driver_bucket_arns"></a> [s3\_csi\_driver\_bucket\_arns](#input\_s3\_csi\_driver\_bucket\_arns) | existing buckets the s3 CSI driver should have access to | `list(string)` | `[]` | no |
| <a name="input_s3_csi_driver_create_bucket"></a> [s3\_csi\_driver\_create\_bucket](#input\_s3\_csi\_driver\_create\_bucket) | create a new bucket for use with the s3 CSI driver | `bool` | `true` | no |
| <a name="input_stack_admin_arns"></a> [stack\_admin\_arns](#input\_stack\_admin\_arns) | arn to the roles for the cluster admins role | `list(string)` | `[]` | no |
| <a name="input_stack_cluster_addons_overrides"></a> [stack\_cluster\_addons\_overrides](#input\_stack\_cluster\_addons\_overrides) | Per-addon overrides keyed by addon name (e.g. "vpc-cni", "kube-proxy", "coredns"). Merges over module defaults — use for version pinning, vpc-cni prefix delegation, custom networking, etc. Accepts any attributes supported by terraform-aws-modules/eks/aws v21+ `addons` map. | `any` | `{}` | no |
| <a name="input_stack_create"></a> [stack\_create](#input\_stack\_create) | should resources be created | `bool` | `true` | no |
| <a name="input_stack_create_pelotech_nat_eip"></a> [stack\_create\_pelotech\_nat\_eip](#input\_stack\_create\_pelotech\_nat\_eip) | should create pelotech nat eip even if NAT isn't enabled - nice for getting ips created for allow lists | `bool` | `false` | no |
| <a name="input_stack_enable_cluster_kms"></a> [stack\_enable\_cluster\_kms](#input\_stack\_enable\_cluster\_kms) | Should secrets be encrypted by kms in the cluster | `bool` | `true` | no |
| <a name="input_stack_enable_coredns_addon"></a> [stack\_enable\_coredns\_addon](#input\_stack\_enable\_coredns\_addon) | Install coredns as a managed addon. Note: coredns will not schedule until a CNI is running and nodes are Ready. | `bool` | `true` | no |
| <a name="input_stack_enable_default_eks_managed_node_group"></a> [stack\_enable\_default\_eks\_managed\_node\_group](#input\_stack\_enable\_default\_eks\_managed\_node\_group) | Ability to disable default node group | `bool` | `true` | no |
| <a name="input_stack_enable_kube_proxy_addon"></a> [stack\_enable\_kube\_proxy\_addon](#input\_stack\_enable\_kube\_proxy\_addon) | Install kube-proxy as a managed addon. Set false when using Cilium with kube-proxy replacement enabled. | `bool` | `true` | no |
| <a name="input_stack_enable_vpc_cni_addon"></a> [stack\_enable\_vpc\_cni\_addon](#input\_stack\_enable\_vpc\_cni\_addon) | Install AWS VPC CNI as a managed addon. Defaults to false so the cluster comes up CNI-less and consumers pick a CNI (Cilium, Kube-OVN, or vpc-cni). Set true to install vpc-cni as a managed addon. When false, nodeadm maxPods=110 cloudinit is applied automatically. | `bool` | `false` | no |
| <a name="input_stack_existing_vpc_config"></a> [stack\_existing\_vpc\_config](#input\_stack\_existing\_vpc\_config) | Setting the VPC | <pre>object({<br/>    vpc_id     = string<br/>    subnet_ids = list(string)<br/>  })</pre> | `null` | no |
| <a name="input_stack_name"></a> [stack\_name](#input\_stack\_name) | Name of the stack | `string` | `"foundation-stack"` | no |
| <a name="input_stack_pelotech_nat_ami_name_filter"></a> [stack\_pelotech\_nat\_ami\_name\_filter](#input\_stack\_pelotech\_nat\_ami\_name\_filter) | ami name filter to find the correct ami | `string` | `"fck-nat-al2023-hvm-*"` | no |
| <a name="input_stack_pelotech_nat_ami_owner_id"></a> [stack\_pelotech\_nat\_ami\_owner\_id](#input\_stack\_pelotech\_nat\_ami\_owner\_id) | Owner ID to search of ami | `string` | `"568608671756"` | no |
| <a name="input_stack_pelotech_nat_enabled"></a> [stack\_pelotech\_nat\_enabled](#input\_stack\_pelotech\_nat\_enabled) | Use pelotech-nat as NAT instances instead of NAT gateway | `bool` | `false` | no |
| <a name="input_stack_pelotech_nat_instance_type"></a> [stack\_pelotech\_nat\_instance\_type](#input\_stack\_pelotech\_nat\_instance\_type) | choose instance based on bandwitch requirements | `string` | `"t4g.micro"` | no |
| <a name="input_stack_ro_arns"></a> [stack\_ro\_arns](#input\_stack\_ro\_arns) | arn to the roles for the cluster read only role, these will also have KMS readonly access for CI plan purposes, more limited access should use the extra entries | `list(string)` | `[]` | no |
| <a name="input_stack_tags"></a> [stack\_tags](#input\_stack\_tags) | tags to be added to the stack, should at least have Owner and Environment | `map(string)` | <pre>{<br/>  "Environment": "prod",<br/>  "Owner": "pelotech"<br/>}</pre> | no |
| <a name="input_stack_vpc_block"></a> [stack\_vpc\_block](#input\_stack\_vpc\_block) | Variables for defining the vpc for the stack | <pre>object({<br/>    cidr             = string<br/>    azs              = list(string)<br/>    private_subnets  = list(string)<br/>    public_subnets   = list(string)<br/>    database_subnets = list(string)<br/>  })</pre> | <pre>{<br/>  "azs": [<br/>    "us-west-2a",<br/>    "us-west-2b",<br/>    "us-west-2c"<br/>  ],<br/>  "cidr": "172.16.0.0/16",<br/>  "database_subnets": [<br/>    "172.16.200.0/24",<br/>    "172.16.201.0/24",<br/>    "172.16.202.0/24"<br/>  ],<br/>  "private_subnets": [<br/>    "172.16.0.0/24",<br/>    "172.16.1.0/24",<br/>    "172.16.2.0/24"<br/>  ],<br/>  "public_subnets": [<br/>    "172.16.100.0/24",<br/>    "172.16.101.0/24",<br/>    "172.16.102.0/24"<br/>  ]<br/>}</pre> | no |
| <a name="input_vpc_endpoints"></a> [vpc\_endpoints](#input\_vpc\_endpoints) | vpc endpoints within the cluster vpc network, note: this only works when using the internal created VPC | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cert_manager_role_arn"></a> [cert\_manager\_role\_arn](#output\_cert\_manager\_role\_arn) | ARN of the Cert Manager IRSA role |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | Cluster security group that was created by Amazon EKS for the cluster |
| <a name="output_ebs_csi_driver_role_arn"></a> [ebs\_csi\_driver\_role\_arn](#output\_ebs\_csi\_driver\_role\_arn) | ARN of the EBS CSI driver IRSA role |
| <a name="output_eks_cluster_certificate_authority_data"></a> [eks\_cluster\_certificate\_authority\_data](#output\_eks\_cluster\_certificate\_authority\_data) | Base64 encoded certificate data for the cluster |
| <a name="output_eks_cluster_endpoint"></a> [eks\_cluster\_endpoint](#output\_eks\_cluster\_endpoint) | The endpoint for the EKS cluster API server |
| <a name="output_eks_cluster_iam_role_name"></a> [eks\_cluster\_iam\_role\_name](#output\_eks\_cluster\_iam\_role\_name) | The name of the EKS cluster IAM role |
| <a name="output_eks_cluster_name"></a> [eks\_cluster\_name](#output\_eks\_cluster\_name) | The name of the EKS cluster |
| <a name="output_eks_cluster_tls_certificate_sha1_fingerprint"></a> [eks\_cluster\_tls\_certificate\_sha1\_fingerprint](#output\_eks\_cluster\_tls\_certificate\_sha1\_fingerprint) | The SHA1 fingerprint of the public key of the cluster's certificate |
| <a name="output_eks_managed_node_groups"></a> [eks\_managed\_node\_groups](#output\_eks\_managed\_node\_groups) | Map of attribute maps for all EKS managed node groups created |
| <a name="output_eks_managed_node_groups_autoscaling_group_names"></a> [eks\_managed\_node\_groups\_autoscaling\_group\_names](#output\_eks\_managed\_node\_groups\_autoscaling\_group\_names) | List of the autoscaling group names created by EKS managed node groups |
| <a name="output_eks_oidc_provider"></a> [eks\_oidc\_provider](#output\_eks\_oidc\_provider) | The OpenID Connect identity provider (issuer URL without leading `https://`) |
| <a name="output_eks_oidc_provider_arn"></a> [eks\_oidc\_provider\_arn](#output\_eks\_oidc\_provider\_arn) | EKS OIDC provider ARN to be able to add IRSA roles to the cluster out of band |
| <a name="output_external_dns_role_arn"></a> [external\_dns\_role\_arn](#output\_external\_dns\_role\_arn) | ARN of the External DNS IRSA role |
| <a name="output_karpenter_node_iam_role_name"></a> [karpenter\_node\_iam\_role\_name](#output\_karpenter\_node\_iam\_role\_name) | The name of the Karpenter node IAM role |
| <a name="output_karpenter_queue_name"></a> [karpenter\_queue\_name](#output\_karpenter\_queue\_name) | The name of the Karpenter SQS queue |
| <a name="output_karpenter_role_arn"></a> [karpenter\_role\_arn](#output\_karpenter\_role\_arn) | ARN of the Karpenter IRSA role |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | The Amazon Resource Name (ARN) of the KMS key |
| <a name="output_load_balancer_controller_role_arn"></a> [load\_balancer\_controller\_role\_arn](#output\_load\_balancer\_controller\_role\_arn) | ARN of the ALB controller IRSA role |
| <a name="output_node_security_group_id"></a> [node\_security\_group\_id](#output\_node\_security\_group\_id) | ID of the node shared security group |
| <a name="output_s3_csi_driver_role_arn"></a> [s3\_csi\_driver\_role\_arn](#output\_s3\_csi\_driver\_role\_arn) | ARN of the S3 CSI driver IRSA role |
| <a name="output_vpc"></a> [vpc](#output\_vpc) | The vpc object when it's created |
<!-- END_TF_DOCS -->
