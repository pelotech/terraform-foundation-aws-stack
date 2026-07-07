![pre-commit](https://github.com/pelotech/terraform-foundation-aws-stack/actions/workflows/pre-commit.yaml/badge.svg)

# Foundation - Pelotech's GitOps K8s Cluster
This is the terraform module that helps bootstrap foundation in AWS

This project uses [release-please](https://github.com/googleapis/release-please) for the release flow of contributions

## Upgrading to v8.0.0 (breaking changes)

This release introduces a single **`stack_cni`** selector that drives the
initial node group's taints/labels *and* the vpc-cni/kube-proxy addon
enablement from one CNI profile. The supported profiles are `cilium`,
`kube-ovn`, and `vpc-cni`, and the **default is now `cilium`** (previously the
defaults silently assumed kube-ovn + multus/nidhogg).

| CNI profile | Taints                                                             | Labels                  | vpc-cni | kube-proxy |
| ----------- | ------------------------------------------------------------------ | ----------------------- | ------- | ---------- |
| `cilium`    | `CriticalAddonsOnly`, `node.cilium.io/agent-not-ready:NO_EXECUTE`  | none                    | off     | off        |
| `kube-ovn`  | `CriticalAddonsOnly`, `nidhogg.uswitch.com/...kube-multus-ds`      | `kube-ovn/role=master`  | off     | on         |
| `vpc-cni`   | `CriticalAddonsOnly`                                               | none                    | on      | on         |

### What happens on first apply against an existing cluster

- **Set `stack_cni` to match your current CNI.** Consumers previously on the
  defaults were effectively running kube-ovn — set `stack_cni = "kube-ovn"`
  to preserve the prior taints/labels and avoid churn.
- **Leaving the default (`cilium`) changes node group taints/labels**, which
  forces the managed node group to roll/replace nodes. Only take the default
  if you intend to run Cilium.
- `stack_enable_vpc_cni_addon` / `stack_enable_kube_proxy_addon` defaults
  changed from `false`/`true` to **`null`** — they now *derive* from
  `stack_cni`. Set them to an explicit `true`/`false` to override the profile.

### Overriding taints/labels

The CNI preset is the base; you can extend or fully replace it:

```hcl
stack_cni = "cilium"

# Add taints/labels on top of the preset (caller keys win):
initial_node_taints_extra = {
  spot = { key = "spot", value = "true", effect = "NO_SCHEDULE" }
}
initial_node_labels_extra = { "team" = "platform" }

# ...or replace the preset entirely (ignores _extra; use {} for none):
# initial_node_taints = { only = { key = "only", value = "true", effect = "NO_SCHEDULE" } }
# initial_node_labels = {}
```

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

The default behavior already supports this: select the CNI with `stack_cni`
(see "CNI selection" below), install your CNI out-of-band (Helm,
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

Pick a CNI with `stack_cni` — it sets the initial node group taints/labels and
the vpc-cni/kube-proxy addon toggles to match. All values remain overridable
(see below).

| `stack_cni`         | vpc-cni | kube-proxy | Node taints/labels                                     | Notes                                                       |
| ------------------- | ------- | ---------- | ------------------------------------------------------ | ----------------------------------------------------------- |
| `cilium` (default)  | off     | off        | `CriticalAddonsOnly` + cilium agent-not-ready          | Install Cilium (kube-proxy replacement) via Helm.           |
| `kube-ovn`          | off     | on         | `CriticalAddonsOnly` + nidhogg/multus, `kube-ovn/role` | Install via Helm/ArgoCD post-bootstrap.                     |
| `vpc-cni`           | on      | on         | `CriticalAddonsOnly`                                    | AWS native. IRSA / prefix delegation via `*_overrides`.     |

For any other CNI, pick the closest profile and override the addon toggles /
taints / labels as needed — anything that wants a clean slate works the same.

### Example: Cilium with kube-proxy replacement

```hcl
module "foundation" {
  # ...
  stack_cni = "cilium" # default; vpc-cni + kube-proxy derived off
}
```

Then install Cilium with `kubeProxyReplacement=true` per the
[Cilium EKS install guide](https://docs.cilium.io/en/stable/installation/k8s-install-helm/).

#### kube-proxy replacement bootstrap (`k8sServiceHost`)

With the `cilium` profile, kube-proxy is **not** installed, so nothing programs
the `kubernetes` Service ClusterIP → API server rule until Cilium is up. The
Cilium agent therefore cannot reach the API server via the in-cluster ClusterIP
during bootstrap (`dial tcp <clusterIP>:443: connect: no route to host`), and
cluster DNS can't help (it resolves to that same unroutable ClusterIP, and
CoreDNS needs the CNI running first). You must point Cilium at the real API
endpoint. Use the `cilium_k8s_service_host` output (the EKS endpoint DNS name,
which resolves via normal DNS with no bootstrap dependency):

```hcl
set { name = "kubeProxyReplacement", value = "true" }
set { name = "k8sServiceHost",       value = module.foundation.cilium_k8s_service_host }
set { name = "k8sServicePort",       value = "443" }
```

To avoid this requirement entirely, keep kube-proxy running — set
`stack_enable_kube_proxy_addon = true` and install Cilium with
`kubeProxyReplacement=false` — at the cost of the eBPF kube-proxy-replacement
benefits (DSR, no iptables scaling cliff).

### Example: Kube-OVN

```hcl
module "foundation" {
  # ...
  stack_cni = "kube-ovn" # vpc-cni off, kube-proxy on, multus/nidhogg taint + kube-ovn/role label
}
```

Install Kube-OVN per the
[upstream install docs](https://kubeovn.github.io/docs/stable/en/start/one-step-install/).

### Bootstrapping the CNI in one apply (`cni-bootstrap` module)

On a CNI-less cluster (`cilium`/`kube-ovn`), the initial node group never reaches
`Ready` until a CNI is installed, so `terraform apply` otherwise blocks ~60m on
the node group before failing. The companion module `modules/cni-bootstrap`
installs the CNI via Helm **concurrently** with the node group: the agent
DaemonSet (hostNetwork, tolerating `NotReady` + the `node.cilium.io/agent-not-ready`
taint) lands on nodes as they register and flips them `Ready` inside the wait
window — one apply, no swap.

Configure a `helm` provider from this module's outputs and use the submodule.
**Do not** make the submodule `depend_on` the node group, or they'd serialize and
the hang returns.

```hcl
provider "helm" {
  kubernetes = {
    host                   = module.foundation.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.foundation.eks_cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.foundation.eks_cluster_name]
    }
  }
}

module "cni_bootstrap" {
  source           = "github.com/pelotech/terraform-foundation-aws-stack//modules/cni-bootstrap"
  cni              = "cilium" # cilium | kube-ovn | custom
  k8s_service_host = module.foundation.cilium_k8s_service_host # for cilium kube-proxy replacement
}
```

For `cni = "kube-ovn"`, also wire `service_cidr = module.foundation.eks_cluster_service_cidr`
(so `ipv4.SVC_CIDR` matches the cluster), plus `cluster_name = module.foundation.eks_cluster_name`
and `region = module.foundation.region` — kube-ovn polls for its master node to
register before installing (needs `aws`+`kubectl` on the apply host).
`cni = "custom"` installs any Helm-packaged CNI via `custom_chart`; layer extra
values with `helm_set` / `helm_values`. See `modules/cni-bootstrap/README.md`.
As a safety net, set `initial_node_timeouts = { create = "20m" }` so a failed
bring-up fails fast instead of 60m. This replaces the imperative
`helm upgrade --install` bootstrap step.

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
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.14.1 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.14.1 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_cert_manager_irsa_role"></a> [cert\_manager\_irsa\_role](#module\_cert\_manager\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.6.1 |
| <a name="module_ebs_csi_driver_irsa_role"></a> [ebs\_csi\_driver\_irsa\_role](#module\_ebs\_csi\_driver\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.6.1 |
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | 21.24.0 |
| <a name="module_external_dns_irsa_role"></a> [external\_dns\_irsa\_role](#module\_external\_dns\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.6.1 |
| <a name="module_fck_nat"></a> [fck\_nat](#module\_fck\_nat) | RaJiska/fck-nat/aws | 1.6.0 |
| <a name="module_karpenter"></a> [karpenter](#module\_karpenter) | terraform-aws-modules/eks/aws//modules/karpenter | 21.24.0 |
| <a name="module_load_balancer_controller_irsa_role"></a> [load\_balancer\_controller\_irsa\_role](#module\_load\_balancer\_controller\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.6.1 |
| <a name="module_s3_csi"></a> [s3\_csi](#module\_s3\_csi) | terraform-aws-modules/s3-bucket/aws | 5.14.1 |
| <a name="module_s3_driver_irsa_role"></a> [s3\_driver\_irsa\_role](#module\_s3\_driver\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.6.1 |
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
| <a name="input_initial_instance_types"></a> [initial\_instance\_types](#input\_initial\_instance\_types) | instance types of the initial managed node group (must all be the same architecture; the node AMI type is derived from them) | `list(string)` | n/a | yes |
| <a name="input_cluster_enabled_log_types"></a> [cluster\_enabled\_log\_types](#input\_cluster\_enabled\_log\_types) | List of EKS control plane log types to enable. Valid values: api, audit, authenticator, controllerManager, scheduler. | `list(string)` | `[]` | no |
| <a name="input_cluster_endpoint_public_access"></a> [cluster\_endpoint\_public\_access](#input\_cluster\_endpoint\_public\_access) | Whether the EKS cluster API server endpoint is publicly accessible. Set to false for private-only access (requires VPC connectivity). | `bool` | `true` | no |
| <a name="input_create_node_security_group"></a> [create\_node\_security\_group](#input\_create\_node\_security\_group) | Whether to create a dedicated security group for EKS managed node groups. When true, the node\_security\_group\_id output is populated. | `bool` | `false` | no |
| <a name="input_eks_cluster_version"></a> [eks\_cluster\_version](#input\_eks\_cluster\_version) | Kubernetes version to set for the cluster | `string` | `"1.35"` | no |
| <a name="input_extra_access_entries"></a> [extra\_access\_entries](#input\_extra\_access\_entries) | EKS access entries needed by IAM roles interacting with this cluster | <pre>list(object({<br/>    principal_arn     = string<br/>    kubernetes_groups = optional(list(string))<br/>    policy_associations = optional(map(object({<br/>      policy_arn = string<br/>      access_scope = object({<br/>        type       = string<br/>        namespaces = optional(list(string))<br/>      })<br/>    })), {})<br/><br/>  }))</pre> | `[]` | no |
| <a name="input_initial_node_desired_size"></a> [initial\_node\_desired\_size](#input\_initial\_node\_desired\_size) | desired size of the initial managed node group | `number` | `3` | no |
| <a name="input_initial_node_labels"></a> [initial\_node\_labels](#input\_initial\_node\_labels) | Full override of the initial managed node group labels. Leave null (default) to derive from stack\_cni merged with initial\_node\_labels\_extra. Set to a map to replace the CNI preset entirely (use {} for no labels). | `map(string)` | `null` | no |
| <a name="input_initial_node_labels_extra"></a> [initial\_node\_labels\_extra](#input\_initial\_node\_labels\_extra) | Extra labels merged over the stack\_cni preset for the initial managed node group (caller keys win). Ignored when initial\_node\_labels is set. | `map(string)` | `{}` | no |
| <a name="input_initial_node_max_size"></a> [initial\_node\_max\_size](#input\_initial\_node\_max\_size) | max size of the initial managed node group | `number` | `6` | no |
| <a name="input_initial_node_min_size"></a> [initial\_node\_min\_size](#input\_initial\_node\_min\_size) | minimum size of the initial managed node group | `number` | `2` | no |
| <a name="input_initial_node_taints"></a> [initial\_node\_taints](#input\_initial\_node\_taints) | Full override of the initial managed node group taints. Leave null (default) to derive from stack\_cni merged with initial\_node\_taints\_extra. Set to a map to replace the CNI preset entirely (use {} for no taints). | `map(object({ key = string, value = string, effect = string }))` | `null` | no |
| <a name="input_initial_node_taints_extra"></a> [initial\_node\_taints\_extra](#input\_initial\_node\_taints\_extra) | Extra taints merged over the stack\_cni preset for the initial managed node group (caller keys win). Ignored when initial\_node\_taints is set. | `map(object({ key = string, value = string, effect = string }))` | `{}` | no |
| <a name="input_initial_node_timeouts"></a> [initial\_node\_timeouts](#input\_initial\_node\_timeouts) | Timeouts for the initial managed node group's create/update/delete. null uses the AWS provider default (60m create). Set e.g. { create = "20m" } to fail fast when a CNI-less cluster's nodes never reach Ready. | <pre>object({<br/>    create = optional(string)<br/>    update = optional(string)<br/>    delete = optional(string)<br/>  })</pre> | `null` | no |
| <a name="input_node_iam_additional_policies"></a> [node\_iam\_additional\_policies](#input\_node\_iam\_additional\_policies) | Map of IAM policy name to ARN to attach to the managed node group IAM role. | `map(string)` | `{}` | no |
| <a name="input_permissions_boundary"></a> [permissions\_boundary](#input\_permissions\_boundary) | IAM permissions boundary policy name applied to all IAM roles. When set, constructs full ARN from the current account and partition. | `string` | `""` | no |
| <a name="input_pre_bootstrap_user_data"></a> [pre\_bootstrap\_user\_data](#input\_pre\_bootstrap\_user\_data) | Custom user data script to run before node bootstrap. Useful for installing CA certificates or custom packages. | `string` | `null` | no |
| <a name="input_s3_csi_driver_bucket_arns"></a> [s3\_csi\_driver\_bucket\_arns](#input\_s3\_csi\_driver\_bucket\_arns) | existing buckets the s3 CSI driver should have access to | `list(string)` | `[]` | no |
| <a name="input_s3_csi_driver_create_bucket"></a> [s3\_csi\_driver\_create\_bucket](#input\_s3\_csi\_driver\_create\_bucket) | create a new bucket for use with the s3 CSI driver | `bool` | `true` | no |
| <a name="input_stack_admin_arns"></a> [stack\_admin\_arns](#input\_stack\_admin\_arns) | arn to the roles for the cluster admins role | `list(string)` | `[]` | no |
| <a name="input_stack_cluster_addons_overrides"></a> [stack\_cluster\_addons\_overrides](#input\_stack\_cluster\_addons\_overrides) | Per-addon overrides keyed by addon name (e.g. "vpc-cni", "kube-proxy", "coredns"). Merges over module defaults — use for version pinning, vpc-cni prefix delegation, custom networking, etc. Accepts any attributes supported by terraform-aws-modules/eks/aws v21+ `addons` map. | `any` | `{}` | no |
| <a name="input_stack_cni"></a> [stack\_cni](#input\_stack\_cni) | CNI profile driving the initial node group taints/labels and vpc-cni/kube-proxy addon enablement. One of: cilium, kube-ovn, vpc-cni. Override individual pieces with initial\_node\_taints(\_extra)/initial\_node\_labels(\_extra) and the stack\_enable\_*\_addon toggles. | `string` | `"cilium"` | no |
| <a name="input_stack_create"></a> [stack\_create](#input\_stack\_create) | should resources be created | `bool` | `true` | no |
| <a name="input_stack_create_pelotech_nat_eip"></a> [stack\_create\_pelotech\_nat\_eip](#input\_stack\_create\_pelotech\_nat\_eip) | should create pelotech nat eip even if NAT isn't enabled - nice for getting ips created for allow lists | `bool` | `false` | no |
| <a name="input_stack_enable_cluster_kms"></a> [stack\_enable\_cluster\_kms](#input\_stack\_enable\_cluster\_kms) | Should secrets be encrypted by kms in the cluster | `bool` | `true` | no |
| <a name="input_stack_enable_coredns_addon"></a> [stack\_enable\_coredns\_addon](#input\_stack\_enable\_coredns\_addon) | Install coredns as a managed addon. Note: coredns will not schedule until a CNI is running and nodes are Ready. | `bool` | `true` | no |
| <a name="input_stack_enable_default_eks_managed_node_group"></a> [stack\_enable\_default\_eks\_managed\_node\_group](#input\_stack\_enable\_default\_eks\_managed\_node\_group) | Ability to disable default node group | `bool` | `true` | no |
| <a name="input_stack_enable_kube_proxy_addon"></a> [stack\_enable\_kube\_proxy\_addon](#input\_stack\_enable\_kube\_proxy\_addon) | Override installation of the kube-proxy managed addon. Leave null (default) to derive from stack\_cni (off for cilium kube-proxy replacement, on for kube-ovn/vpc-cni). Set true/false to force. | `bool` | `null` | no |
| <a name="input_stack_enable_vpc_cni_addon"></a> [stack\_enable\_vpc\_cni\_addon](#input\_stack\_enable\_vpc\_cni\_addon) | Override installation of the AWS VPC CNI managed addon. Leave null (default) to derive from stack\_cni (on for vpc-cni, off for cilium/kube-ovn). Set true/false to force. When the addon is off, nodeadm maxPods=110 cloudinit is applied automatically. | `bool` | `null` | no |
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
| <a name="output_cilium_k8s_service_host"></a> [cilium\_k8s\_service\_host](#output\_cilium\_k8s\_service\_host) | Kubernetes API server host (no https:// scheme) for Cilium kubeProxyReplacement=true. Set helm k8sServiceHost to this and k8sServicePort to 443. |
| <a name="output_cluster_addons_enabled_resolved"></a> [cluster\_addons\_enabled\_resolved](#output\_cluster\_addons\_enabled\_resolved) | (introspection) Managed addon enablement after resolving stack\_cni and the stack\_enable\_*\_addon overrides |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | Cluster security group that was created by Amazon EKS for the cluster |
| <a name="output_ebs_csi_driver_role_arn"></a> [ebs\_csi\_driver\_role\_arn](#output\_ebs\_csi\_driver\_role\_arn) | ARN of the EBS CSI driver IRSA role |
| <a name="output_eks_cluster_certificate_authority_data"></a> [eks\_cluster\_certificate\_authority\_data](#output\_eks\_cluster\_certificate\_authority\_data) | Base64 encoded certificate data for the cluster |
| <a name="output_eks_cluster_endpoint"></a> [eks\_cluster\_endpoint](#output\_eks\_cluster\_endpoint) | The endpoint for the EKS cluster API server |
| <a name="output_eks_cluster_iam_role_name"></a> [eks\_cluster\_iam\_role\_name](#output\_eks\_cluster\_iam\_role\_name) | The name of the EKS cluster IAM role |
| <a name="output_eks_cluster_name"></a> [eks\_cluster\_name](#output\_eks\_cluster\_name) | The name of the EKS cluster |
| <a name="output_eks_cluster_service_cidr"></a> [eks\_cluster\_service\_cidr](#output\_eks\_cluster\_service\_cidr) | The cluster's Kubernetes service CIDR (AWS-assigned or configured). Wire into the cni-bootstrap module's service\_cidr for kube-ovn (ipv4.SVC\_CIDR). |
| <a name="output_eks_cluster_tls_certificate_sha1_fingerprint"></a> [eks\_cluster\_tls\_certificate\_sha1\_fingerprint](#output\_eks\_cluster\_tls\_certificate\_sha1\_fingerprint) | The SHA1 fingerprint of the public key of the cluster's certificate |
| <a name="output_eks_managed_node_groups"></a> [eks\_managed\_node\_groups](#output\_eks\_managed\_node\_groups) | Map of attribute maps for all EKS managed node groups created |
| <a name="output_eks_managed_node_groups_autoscaling_group_names"></a> [eks\_managed\_node\_groups\_autoscaling\_group\_names](#output\_eks\_managed\_node\_groups\_autoscaling\_group\_names) | List of the autoscaling group names created by EKS managed node groups |
| <a name="output_eks_oidc_provider"></a> [eks\_oidc\_provider](#output\_eks\_oidc\_provider) | The OpenID Connect identity provider (issuer URL without leading `https://`) |
| <a name="output_eks_oidc_provider_arn"></a> [eks\_oidc\_provider\_arn](#output\_eks\_oidc\_provider\_arn) | EKS OIDC provider ARN to be able to add IRSA roles to the cluster out of band |
| <a name="output_external_dns_role_arn"></a> [external\_dns\_role\_arn](#output\_external\_dns\_role\_arn) | ARN of the External DNS IRSA role |
| <a name="output_initial_node_labels_resolved"></a> [initial\_node\_labels\_resolved](#output\_initial\_node\_labels\_resolved) | (introspection) Labels applied to the initial managed node group after resolving stack\_cni, initial\_node\_labels, and initial\_node\_labels\_extra |
| <a name="output_initial_node_taints_resolved"></a> [initial\_node\_taints\_resolved](#output\_initial\_node\_taints\_resolved) | (introspection) Taints applied to the initial managed node group after resolving stack\_cni, initial\_node\_taints, and initial\_node\_taints\_extra |
| <a name="output_karpenter_node_iam_role_name"></a> [karpenter\_node\_iam\_role\_name](#output\_karpenter\_node\_iam\_role\_name) | The name of the Karpenter node IAM role |
| <a name="output_karpenter_queue_name"></a> [karpenter\_queue\_name](#output\_karpenter\_queue\_name) | The name of the Karpenter SQS queue |
| <a name="output_karpenter_role_arn"></a> [karpenter\_role\_arn](#output\_karpenter\_role\_arn) | ARN of the Karpenter IRSA role |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | The Amazon Resource Name (ARN) of the KMS key |
| <a name="output_load_balancer_controller_role_arn"></a> [load\_balancer\_controller\_role\_arn](#output\_load\_balancer\_controller\_role\_arn) | ARN of the ALB controller IRSA role |
| <a name="output_node_security_group_id"></a> [node\_security\_group\_id](#output\_node\_security\_group\_id) | ID of the node shared security group |
| <a name="output_region"></a> [region](#output\_region) | The AWS region the stack is deployed in. Wire into the cni-bootstrap module's region so its node-registration poll can region-qualify the cluster. |
| <a name="output_s3_csi_driver_role_arn"></a> [s3\_csi\_driver\_role\_arn](#output\_s3\_csi\_driver\_role\_arn) | ARN of the S3 CSI driver IRSA role |
| <a name="output_vpc"></a> [vpc](#output\_vpc) | The vpc object when it's created |
<!-- END_TF_DOCS -->
