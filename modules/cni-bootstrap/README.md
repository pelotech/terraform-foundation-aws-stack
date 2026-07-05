# cni-bootstrap

Installs a Kubernetes CNI via Helm as part of `terraform apply`, so a CNI-less
EKS cluster's initial node group reaches `Ready` without the ~60m
`aws_eks_node_group` hang. Ships built-in defaults for **cilium** and
**kube-ovn**, plus a **custom** option for any Helm-packaged CNI.

Because this module depends only on the cluster (not the node group), Terraform
provisions the `helm_release` concurrently with the node group; the CNI agent
DaemonSet (hostNetwork, tolerating `NotReady`) lands on nodes as they register
and flips them `Ready` inside the node group's wait window.

## Usage

The consumer configures a `helm` provider (this module does not configure
providers) from the foundation module's outputs, then calls this module:

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
  cni              = "cilium"
  k8s_service_host = module.foundation.cilium_k8s_service_host
}
```

Do **not** add `depends_on = [<node group>]` — that serializes the install after
the node group and reintroduces the hang.

### Custom CNI

```hcl
module "cni_bootstrap" {
  source = "github.com/pelotech/terraform-foundation-aws-stack//modules/cni-bootstrap"
  cni    = "custom"
  custom_chart = {
    repository = "https://example.com/charts"
    chart      = "my-cni"
    version    = "1.2.3"
  }
  helm_set = [{ name = "some.value", value = "true" }]
}
```

> The kube-ovn chart default is a best-effort starting point and usually needs
> value tuning for your topology — use `chart_version` / `helm_set` /
> `helm_values`. It pairs with the `kube-ovn/role=master` node label set by
> `stack_cni = "kube-ovn"` in the foundation module.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 3.0.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_helm"></a> [helm](#provider\_helm) | >= 3.0.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.cni](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_chart_version"></a> [chart\_version](#input\_chart\_version) | Override the CNI Helm chart version. null uses the built-in default for the selected cni (ignored for custom, which uses custom\_chart.version). | `string` | `null` | no |
| <a name="input_cni"></a> [cni](#input\_cni) | Which CNI to install. One of: cilium, kube-ovn, custom. Use custom with custom\_chart to install any Helm-packaged CNI. | `string` | `"cilium"` | no |
| <a name="input_create"></a> [create](#input\_create) | Whether to install the CNI Helm release. | `bool` | `true` | no |
| <a name="input_custom_chart"></a> [custom\_chart](#input\_custom\_chart) | Chart coordinates for cni=custom. Required when cni=custom, ignored otherwise. | <pre>object({<br/>    repository = string<br/>    chart      = string<br/>    version    = string<br/>  })</pre> | `null` | no |
| <a name="input_helm_set"></a> [helm\_set](#input\_helm\_set) | Extra Helm --set values merged over the CNI defaults (caller entries take effect after the defaults). | `list(object({ name = string, value = string }))` | `[]` | no |
| <a name="input_helm_values"></a> [helm\_values](#input\_helm\_values) | Extra raw Helm values YAML documents (like -f), applied in order. | `list(string)` | `[]` | no |
| <a name="input_k8s_service_host"></a> [k8s\_service\_host](#input\_k8s\_service\_host) | API server host (no scheme) for Cilium kube-proxy replacement bootstrap. Wire from the foundation module's cilium\_k8s\_service\_host output. Ignored unless cni=cilium and kube\_proxy\_replacement=true. | `string` | `""` | no |
| <a name="input_kube_proxy_replacement"></a> [kube\_proxy\_replacement](#input\_kube\_proxy\_replacement) | Enable Cilium kube-proxy replacement (cni=cilium only). When true, k8sServiceHost/k8sServicePort are set from k8s\_service\_host. | `bool` | `true` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace to install the CNI release into. | `string` | `"kube-system"` | no |
| <a name="input_wait_timeout"></a> [wait\_timeout](#input\_wait\_timeout) | Seconds to wait for the Helm release to become ready. | `number` | `600` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace the CNI release was installed into. |
| <a name="output_release_name"></a> [release\_name](#output\_release\_name) | Name of the installed CNI Helm release (null when create=false). |
| <a name="output_resolved_set"></a> [resolved\_set](#output\_resolved\_set) | Effective Helm --set values (CNI defaults merged with helm\_set). |
| <a name="output_resolved_version"></a> [resolved\_version](#output\_resolved\_version) | Chart version selected after applying cni defaults and chart\_version override. |
<!-- END_TF_DOCS -->
