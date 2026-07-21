![pre-commit](https://github.com/pelotech/terraform-foundation-aws-stack/actions/workflows/pre-commit.yaml/badge.svg)

# Foundation - Pelotech's GitOps K8s Cluster
This is the terraform module that helps bootstrap foundation in AWS

This project uses [release-please](https://github.com/googleapis/release-please) for the release flow of contributions

## Upgrading to v8.0.0 (breaking changes)

### Interface rename & regrouping

Every input lost its `stack_` prefix and related settings merged into grouped
object variables. Values migrate 1:1 — a consumer that maps old values to their
new locations gets an **empty plan** (no resource replacement; access-entry state
keys are preserved).

| Old variable (v7) | New location (v8) |
| ----------------- | ----------------- |
| `stack_name` / `stack_create` / `eks_cluster_version` / `stack_tags` / `stack_cni` / `stack_enable_cluster_kms` | `name` / `create` / `cluster_version` / `tags` / `cni` / `create_cluster_kms` |
| `stack_vpc_block` / `stack_existing_vpc_config` | `vpc` / `existing_vpc` |
| `stack_enable_vpc_cni_addon`, `stack_enable_kube_proxy_addon`, `stack_enable_coredns_addon`, `stack_cluster_addons_overrides` | `addons.{vpc_cni, kube_proxy, coredns, overrides}` |
| `initial_instance_types`, `stack_enable_default_eks_managed_node_group`, `initial_node_{min,max,desired}_size`, `initial_node_taints(_extra)`, `initial_node_labels(_extra)`, `initial_node_timeouts` | `initial_node.{instance_types, enabled, min_size, max_size, desired_size, taints, taints_extra, labels, labels_extra, timeouts}` |
| `stack_enable_cni_node_group`, `cni_node_kubernetes_version`, `cni_node_instance_types`, `cni_node_ami_release_version`, `cni_node_size` | `cni_node.{enabled, kubernetes_version, instance_types, ami_release_version, size}` |
| `stack_pelotech_nat_{enabled, instance_type, ami_owner_id, ami_name_filter}`, `stack_create_pelotech_nat_eip`, `stack_pelotech_nat_tailscale` | `pelotech_nat.{enabled, instance_type, ami_owner_id, ami_name_filter, create_eip, tailscale}` |
| `stack_pelotech_nat_tailscale_auth_key` | `pelotech_nat_tailscale_auth_key` (still top-level; sensitive) |
| `stack_admin_arns` / `stack_admin_ro_arns` / `stack_ro_arns` | `access.{admin_arns, admin_ro_arns, ro_arns}` |
| `s3_csi_driver_create_bucket` / `s3_csi_driver_bucket_arns` | `s3_csi.{create_bucket, bucket_arns}` |
| unchanged | `cluster_enabled_log_types`, `cluster_endpoint_public_access`, `create_node_security_group`, `permissions_boundary`, `pre_bootstrap_user_data`, `node_iam_additional_policies`, `vpc_endpoints`, `extra_access_entries` |

### Pelotech NAT AMI now comes from AWS Marketplace (subscription required)

The `pelotech_nat` AMI defaults moved from the public fck-nat image
(owner `568608671756`, `fck-nat-al2023-hvm-*`, no subscription needed) to the
**Pelotech NAT product on AWS Marketplace** (`ami_owner_id = "aws-marketplace"`,
`ami_name_filter = "pelotech-nat-al2023-hvm-*"`). Unlike the plain public image,
Pelotech NAT is hardened for security-sensitive environments — FIPS and L2
compliance — and includes optional integrations like Tailscale. Existing NAT
users must **subscribe in each target account before upgrading** — see
["Pelotech NAT instances"](#pelotech-nat-instances-aws-marketplace) — or pin the
old public image back via `pelotech_nat = { ami_owner_id = "568608671756", ami_name_filter = "fck-nat-al2023-hvm-*" }`.

### CNI profile selector

This release introduces a single **`cni`** selector that drives the initial
node group's taints/labels *and* the vpc-cni/kube-proxy addon enablement from one
CNI profile. The supported profiles are `cilium`, `kube-ovn`, and `vpc-cni`, and
the **default is now `cilium`** (previously the defaults silently assumed kube-ovn
+ multus/nidhogg). The taints/labels below apply to the **initial (system) node
group**; for `kube-ovn` the master label + nidhogg taint move to a dedicated CNI
node group (see the note under the table).

| CNI profile | Initial-group taints                                              | Initial-group labels | vpc-cni | kube-proxy |
| ----------- | ----------------------------------------------------------------- | -------------------- | ------- | ---------- |
| `cilium`    | `CriticalAddonsOnly`, `node.cilium.io/agent-not-ready:NO_EXECUTE` | none                 | off     | off        |
| `kube-ovn`  | `CriticalAddonsOnly`                                              | none                 | off     | on         |
| `vpc-cni`   | `CriticalAddonsOnly`                                              | none                 | on      | on         |

> **kube-ovn** additionally provisions a dedicated 1-node `cni-<stack>` node group
> that carries the `kube-ovn/role=master` label + the `nidhogg…kube-multus-ds`
> taint and hosts `ovn-central` — kept separate so upgrades recycle it without
> touching the system group. See ["Node upgrades on kube-ovn"](#node-upgrades-on-kube-ovn-version-bumps--security-patches).

### What happens on first apply against an existing cluster

- **Set `cni` to match your current CNI.** Consumers previously on the
  defaults were effectively running kube-ovn — set `cni = "kube-ovn"` (and
  `cni_node.kubernetes_version`, now required). Note this **provisions the new
  dedicated `cni-<stack>` node group** and moves the master label/nidhogg taint
  off the initial group, so expect the new group plus an initial-group roll — it
  does **not** preserve the old single-group layout unchanged.
- **Leaving the default (`cilium`) changes node group taints/labels**, which
  forces the managed node group to roll/replace nodes. Only take the default
  if you intend to run Cilium.
- `addons.vpc_cni` / `addons.kube_proxy` defaults
  changed from `false`/`true` to **`null`** — they now *derive* from
  `cni`. Set them to an explicit `true`/`false` to override the profile.

### Overriding taints/labels

The CNI preset is the base; you can extend or fully replace it:

```hcl
cni = "cilium"

initial_node = {
  instance_types = ["m7g.large"]

  # Add taints/labels on top of the preset (caller keys win):
  taints_extra = {
    spot = { key = "spot", value = "true", effect = "NO_SCHEDULE" }
  }
  labels_extra = { "team" = "platform" }

  # ...or replace the preset entirely (ignores _extra; use {} for none):
  # taints = { only = { key = "only", value = "true", effect = "NO_SCHEDULE" } }
  # labels = {}
}
```

### Read-only / CI access split

`access.ro_arns` now grants only `AmazonEKSViewPolicy` (view resources, **not**
Secrets) and **no longer receives KMS access**. A new **`access.admin_ro_arns`**
grants `AmazonEKSAdminViewPolicy` (read Secrets + ConfigMaps) plus KMS read
(via `kms_key_administrators`), intended for CI `terraform plan`.

**Migration:** move any CI plan role that must read cluster Secrets or decrypt
KMS during plan (e.g. `gh-pr-plan`) from `access.ro_arns` → `access.admin_ro_arns`.
Roles needing only plain read-only stay in `access.ro_arns`.

> **You may need to run `terraform apply` twice.** The principal moves between two
> separately-keyed access-entry sets (`ro_*` → `admin_ro_*`) for the same
> `principal_arn`, so Terraform can try to create the new access entry before
> deleting the old one — and AWS allows only one access entry per principal, so the
> first apply may fail with an "already exists" error. Re-run `terraform apply` and
> it completes (the old entry is gone by the second run).

### Node upgrades on kube-ovn (version bumps & security patches)

kube-ovn pins `ovn-central` to the master nodes present at deploy time (via
`MASTER_NODES_LABEL`), so replacing those nodes with a normal in-place EKS rolling
update breaks it mid-roll and deadlocks. Node replacement must be a **deliberate
recycle** (destroy/recreate).

**How it's structured:** for `cni = "kube-ovn"` the module runs **two** node
groups — the `initial-<stack>` **system group** (coredns + critical addons; carries
only `CriticalAddonsOnly`; follows `cluster_version`; rolls in place) and a
dedicated 1-node `cni-<stack>` **control-plane group** (`kube-ovn/role=master` +
nidhogg taint; version-pinned; recycled). Because the recycle destroys **only the
1-node CNI group**, coredns/DNS and the system group stay up — no coredns/PDB dance,
and at most one coredns replica is ever disrupted so its PDB is always satisfied.
(`cilium`/`vpc-cni` get just the one initial group.)

**Breaking:** for `cni = "kube-ovn"` you must set **`cni_node.kubernetes_version`**
(pin the CNI group's k8s version). This decouples it from `cluster_version`, so a
control-plane bump does **not** auto-roll the master node.

**Upgrade runbook (recycle; small kube-ovn control-plane blip):**
1. Bump `cluster_version`, leaving `cni_node.kubernetes_version` at the **current** version → `apply`. Control plane upgrades; the system group rolls in place; the CNI group is untouched (kube-ovn healthy).
2. Set `cni_node.enabled = false` → `apply`. The 1-node CNI group is destroyed; `ovn-central` down briefly — **coredns/DNS and the system group stay up**.
3. Set `cni_node.enabled = true`, set `cni_node.kubernetes_version` to the new version, and **bump `bootstrap_generation`** on the `cni-bootstrap` module (any new value — e.g. the new version — forces the poll to re-run and kube-ovn to re-apply) → `apply`. A fresh CNI node is created at the new version → registers → the poll gates → kube-ovn re-applies against the new master → `Ready`.

> **The step 2 → step 3 ordering is load-bearing.** Step 2's `apply` must
> **fully complete** (the old CNI node destroyed) before you re-enable in step 3.
> The re-apply relies on there being exactly **one** `kube-ovn/role=master` node so
> the poll and kube-ovn bind the *new* master. If you bump `bootstrap_generation`
> while the old master is still registered — e.g. by combining steps 2 and 3 into a
> single apply — the poll binds the **stale** node and kube-ovn re-applies against
> the old IP: a silent no-op (the node isn't actually recycled). Keep them as two
> separate applies.

**Security patch (same k8s version):** skip step 1; in steps 2–3 bump
`cni_node.ami_release_version` (instead of the k8s version) together with
`bootstrap_generation`.

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

Pick a CNI with `cni` — it sets the initial node group taints/labels and
the vpc-cni/kube-proxy addon toggles to match. All values remain overridable
(see below).

| `cni`               | vpc-cni | kube-proxy | Initial-group taints/labels                   | Notes                                                       |
| ------------------- | ------- | ---------- | --------------------------------------------- | ----------------------------------------------------------- |
| `cilium` (default)  | off     | off        | `CriticalAddonsOnly` + cilium agent-not-ready | Install Cilium (kube-proxy replacement) via Helm.           |
| `kube-ovn`          | off     | on         | `CriticalAddonsOnly`                           | Also adds a dedicated CNI node group (see note). Install via Helm/ArgoCD post-bootstrap. |
| `vpc-cni`           | on      | on         | `CriticalAddonsOnly`                           | AWS native. IRSA / prefix delegation via `*_overrides`.     |

> **kube-ovn** provisions an extra dedicated 1-node `cni-<stack>` node group that
> carries the `kube-ovn/role=master` label + the `nidhogg…kube-multus-ds` taint
> (not the system group) and requires `cni_node.kubernetes_version`. See
> ["Node upgrades on kube-ovn"](#node-upgrades-on-kube-ovn-version-bumps--security-patches).

For any other CNI, pick the closest profile and override the addon toggles /
taints / labels as needed — anything that wants a clean slate works the same.

### Example: Cilium with kube-proxy replacement

```hcl
module "foundation" {
  # ...
  cni = "cilium" # default; vpc-cni + kube-proxy derived off
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
`addons = { kube_proxy = true }` and install Cilium with
`kubeProxyReplacement=false` — at the cost of the eBPF kube-proxy-replacement
benefits (DSR, no iptables scaling cliff).

### Example: Kube-OVN

```hcl
module "foundation" {
  # ...
  cni = "kube-ovn" # vpc-cni off, kube-proxy on; system group gets only CriticalAddonsOnly

  # kubernetes_version is required for kube-ovn: pins the dedicated CNI node group
  # (kube-ovn/role=master + nidhogg taint) so a control-plane bump never auto-rolls
  # the master node.
  cni_node = { kubernetes_version = "1.35" }
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
As a safety net, set `initial_node = { ..., timeouts = { create = "20m" } }` so a failed
bring-up fails fast instead of 60m. This replaces the imperative
`helm upgrade --install` bootstrap step.

### Power-user overrides

Pin addon versions or pass addon-specific configuration (e.g. vpc-cni prefix
delegation) via `addons.overrides`:

```hcl
addons = {
  overrides = {
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
}
```

## Pelotech NAT instances (AWS Marketplace)

Setting `pelotech_nat = { enabled = true }` replaces the managed NAT gateway
with per-AZ NAT instances launched from the **Pelotech NAT AMI on AWS
Marketplace** — a fck-nat-based image hardened for security-sensitive
environments (FIPS and L2 compliance) with optional integrations like
Tailscale.

> **Subscription required.** Each target AWS account must hold an active
> Marketplace subscription to the Pelotech NAT product **before** applying —
> otherwise the instance launch fails at apply time with
> `OptInRequired: In order to use this AWS Marketplace product you need to
> accept terms and subscribe`. Subscribe via the AWS Marketplace console
> (search for "pelotech-nat"); use the product ID below to confirm you have
> the right listing.

| Product    | Architecture | Product ID           |
| ---------- | ------------ | -------------------- |
| commercial | arm64        | `prod-gsytpkjrvz55c` |
| commercial | x86_64       | `prod-nwuwmpkklwra2` |
| GovCloud   | arm64        | `prod-klr44ptdose4y` |
| GovCloud   | x86_64       | `prod-5hmnt2qqdjbpg` |

The architecture is derived from `pelotech_nat.instance_type` — the default
`t4g.micro` is arm64, so the **arm64** product is the one you need by default.

To use your own image instead (no subscription), point the module at it:

```hcl
pelotech_nat = {
  enabled         = true
  ami_owner_id    = "123456789012"      # your account
  ami_name_filter = "my-nat-al2023-*"
}
```

## Private VPC endpoints

Populate `vpc_endpoints` with endpoint service short-names to provision private
VPC endpoints in the module-created VPC; empty (the default) creates none.
`s3`/`dynamodb` become **free Gateway** endpoints and every other name becomes an
**Interface** endpoint. Each is opt-in — e.g. `vpc_endpoints = ["s3"]` provisions
only the S3 gateway.

This lets private-subnet nodes reach ECR/STS/SSM/EC2 — so they can bootstrap and be
**SSM-debuggable even when NAT egress is down or still provisioning** (kubelet→API
already works privately via the cluster's `endpoint_private_access` ENIs). It also
enables a NAT-less private topology.

Recommended set for private/NAT-resilient clusters:

```hcl
vpc_endpoints = ["s3", "ssm", "ssmmessages", "ec2messages", "ec2", "ecr.api", "ecr.dkr", "sts", "elasticloadbalancing", "autoscaling"]
```

> Gateway endpoints (`s3`/`dynamodb`) are free; Interface endpoints cost ~$7/mo per
> endpoint **per AZ** (≈ $22/mo per service across 3 AZs) plus data processing —
> hence opt-in. Applies only to the
> module-created VPC; with `existing_vpc` you manage endpoints yourself.

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
| <a name="module_vpc_endpoints"></a> [vpc\_endpoints](#module\_vpc\_endpoints) | terraform-aws-modules/vpc/aws//modules/vpc-endpoints | 6.6.1 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eip.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_iam_role_policy.nat_tailscale_ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_ssm_parameter.nat_tailscale_auth_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ami.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.source](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_initial_node"></a> [initial\_node](#input\_initial\_node) | Initial (system) managed node group. instance\_types is required and must all be one architecture (the node AMI type is derived from them). taints/labels: leave null to derive from the cni profile merged with taints\_extra/labels\_extra (caller keys win); set to a map to replace the preset entirely ({} for none). | <pre>object({<br/>    instance_types = list(string)<br/>    enabled        = optional(bool, true)<br/>    min_size       = optional(number, 2)<br/>    max_size       = optional(number, 6)<br/>    desired_size   = optional(number, 3)<br/>    taints         = optional(map(object({ key = string, value = string, effect = string })))<br/>    taints_extra   = optional(map(object({ key = string, value = string, effect = string })), {})<br/>    labels         = optional(map(string))<br/>    labels_extra   = optional(map(string), {})<br/>    timeouts = optional(object({<br/>      create = optional(string)<br/>      update = optional(string)<br/>      delete = optional(string)<br/>    }))<br/>  })</pre> | n/a | yes |
| <a name="input_access"></a> [access](#input\_access) | IAM role ARNs granted cluster access. admin\_arns: cluster admins. admin\_ro\_arns: admin read only with secret and configmap access. ro\_arns: read only. Both *\_ro groups also get KMS readonly access for CI plan purposes; more limited access should use extra\_access\_entries. | <pre>object({<br/>    admin_arns    = optional(list(string), [])<br/>    admin_ro_arns = optional(list(string), [])<br/>    ro_arns       = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| <a name="input_addons"></a> [addons](#input\_addons) | Managed cluster addon toggles and overrides. vpc\_cni/kube\_proxy: leave null (default) to derive from the cni profile (vpc-cni: on for cni=vpc-cni; kube-proxy: off for cilium kube-proxy replacement); set true/false to force. When the vpc-cni addon is off, nodeadm maxPods=110 cloudinit is applied automatically. overrides: per-addon overrides keyed by addon name (e.g. "vpc-cni", "kube-proxy", "coredns") merged over module defaults — accepts any attributes supported by terraform-aws-modules/eks/aws v21+ `addons` map. | <pre>object({<br/>    vpc_cni    = optional(bool)<br/>    kube_proxy = optional(bool)<br/>    coredns    = optional(bool, true)<br/>    overrides  = optional(any, {})<br/>  })</pre> | `{}` | no |
| <a name="input_cluster_enabled_log_types"></a> [cluster\_enabled\_log\_types](#input\_cluster\_enabled\_log\_types) | List of EKS control plane log types to enable. Valid values: api, audit, authenticator, controllerManager, scheduler. | `list(string)` | `[]` | no |
| <a name="input_cluster_endpoint_public_access"></a> [cluster\_endpoint\_public\_access](#input\_cluster\_endpoint\_public\_access) | Whether the EKS cluster API server endpoint is publicly accessible. Set to false for private-only access (requires VPC connectivity). | `bool` | `true` | no |
| <a name="input_cluster_version"></a> [cluster\_version](#input\_cluster\_version) | Kubernetes version to set for the cluster | `string` | `"1.35"` | no |
| <a name="input_cni"></a> [cni](#input\_cni) | CNI profile driving the initial (system) node group taints/labels and vpc-cni/kube-proxy addon enablement. One of: cilium, kube-ovn, vpc-cni. For kube-ovn the kube-ovn/role=master label + nidhogg taint move to a dedicated CNI node group (the cni\_node variable), not the system group. Override individual pieces with initial\_node.taints(\_extra)/labels(\_extra) and the addons toggles. | `string` | `"cilium"` | no |
| <a name="input_cni_node"></a> [cni\_node](#input\_cni\_node) | Dedicated CNI node group (kube-ovn control plane). enabled: null derives from cni (true for kube-ovn, false otherwise); set false, apply, then true again to recycle it (e.g. for a version/AMI upgrade) without touching the initial group. kubernetes\_version: version this group runs — bump to upgrade it; decoupled from cluster\_version so a control-plane bump doesn't auto-roll it (null follows cluster\_version, REQUIRED for cni="kube-ovn"); replace it deliberately via the recycle (toggle enabled + bump cni-bootstrap's bootstrap\_generation). instance\_types: null falls back to initial\_node.instance\_types; must all be one architecture. ami\_release\_version: pin the AMI release (e.g. a same-version security patch); null uses the default AMI for its kubernetes\_version. size: node count (min=max=desired); default 1 = a single kube-ovn ovn-central master. | <pre>object({<br/>    enabled             = optional(bool)<br/>    kubernetes_version  = optional(string)<br/>    instance_types      = optional(list(string))<br/>    ami_release_version = optional(string)<br/>    size                = optional(number, 1)<br/>  })</pre> | `{}` | no |
| <a name="input_create"></a> [create](#input\_create) | should resources be created | `bool` | `true` | no |
| <a name="input_create_cluster_kms"></a> [create\_cluster\_kms](#input\_create\_cluster\_kms) | Should secrets be encrypted by kms in the cluster | `bool` | `true` | no |
| <a name="input_create_node_security_group"></a> [create\_node\_security\_group](#input\_create\_node\_security\_group) | Whether to create a dedicated security group for EKS managed node groups. When true, the node\_security\_group\_id output is populated. | `bool` | `false` | no |
| <a name="input_existing_vpc"></a> [existing\_vpc](#input\_existing\_vpc) | Use an existing VPC instead of creating one (null = create the VPC from the vpc variable) | <pre>object({<br/>    vpc_id     = string<br/>    subnet_ids = list(string)<br/>  })</pre> | `null` | no |
| <a name="input_extra_access_entries"></a> [extra\_access\_entries](#input\_extra\_access\_entries) | EKS access entries needed by IAM roles interacting with this cluster | <pre>list(object({<br/>    principal_arn     = string<br/>    kubernetes_groups = optional(list(string))<br/>    policy_associations = optional(map(object({<br/>      policy_arn = string<br/>      access_scope = object({<br/>        type       = string<br/>        namespaces = optional(list(string))<br/>      })<br/>    })), {})<br/><br/>  }))</pre> | `[]` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the stack | `string` | `"foundation-stack"` | no |
| <a name="input_node_iam_additional_policies"></a> [node\_iam\_additional\_policies](#input\_node\_iam\_additional\_policies) | Map of IAM policy name to ARN to attach to the managed node group IAM role. | `map(string)` | `{}` | no |
| <a name="input_pelotech_nat"></a> [pelotech\_nat](#input\_pelotech\_nat) | Pelotech NAT instances replacing the managed NAT gateway — a hardened fck-nat-based image (FIPS, L2 compliance, optional Tailscale) from AWS Marketplace. IMPORTANT: the default AMI is the Pelotech NAT image from AWS Marketplace and requires an active Marketplace subscription in the target account — without one the instance launch fails at apply time with OptInRequired. Subscribe first, or point ami\_owner\_id/ami\_name\_filter at your own image. create\_eip creates the NAT EIP even when enabled=false — nice for getting ips created for allow lists. tailscale: provide auth via tailscale.auth\_key\_ssm (name of an existing SSM parameter) or pelotech\_nat\_tailscale\_auth\_key (plain key; the module stores it in a SecureString SSM parameter it creates). The instances always read the key from SSM. SecureString params under the default aws/ssm KMS key work as-is; customer-managed KMS keys on an existing parameter require a key-policy grant outside this module. | <pre>object({<br/>    enabled         = optional(bool, false)<br/>    instance_type   = optional(string, "t4g.micro")<br/>    ami_owner_id    = optional(string, "aws-marketplace")<br/>    ami_name_filter = optional(string, "pelotech-nat-al2023-hvm-*")<br/>    create_eip      = optional(bool, false)<br/>    tailscale = optional(object({<br/>      enabled            = optional(bool, false)<br/>      auth_key_ssm       = optional(string, "")<br/>      advertise_routes   = optional(string, "")<br/>      exit_node          = optional(bool, false)<br/>      hostname           = optional(string, "")<br/>      snat_subnet_routes = optional(bool, true)<br/>      extra_args         = optional(string, "")<br/>    }), {})<br/>  })</pre> | `{}` | no |
| <a name="input_pelotech_nat_tailscale_auth_key"></a> [pelotech\_nat\_tailscale\_auth\_key](#input\_pelotech\_nat\_tailscale\_auth\_key) | Plain Tailscale auth key for NAT instances. Stored by the module in a SecureString SSM parameter (never written to user-data; the value does land in terraform state - prefer pelotech\_nat.tailscale.auth\_key\_ssm with a pre-existing parameter). | `string` | `""` | no |
| <a name="input_permissions_boundary"></a> [permissions\_boundary](#input\_permissions\_boundary) | IAM permissions boundary policy name applied to all IAM roles. When set, constructs full ARN from the current account and partition. | `string` | `""` | no |
| <a name="input_pre_bootstrap_user_data"></a> [pre\_bootstrap\_user\_data](#input\_pre\_bootstrap\_user\_data) | Custom user data script to run before node bootstrap. Useful for installing CA certificates or custom packages. | `string` | `null` | no |
| <a name="input_s3_csi"></a> [s3\_csi](#input\_s3\_csi) | S3 CSI driver bucket access. create\_bucket: create a new bucket for use with the driver. bucket\_arns: existing buckets the driver should have access to. | <pre>object({<br/>    create_bucket = optional(bool, true)<br/>    bucket_arns   = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | tags to be added to the stack, should at least have Owner and Environment | `map(string)` | <pre>{<br/>  "Environment": "prod",<br/>  "Owner": "pelotech"<br/>}</pre> | no |
| <a name="input_vpc"></a> [vpc](#input\_vpc) | Variables for defining the vpc for the stack (ignored when existing\_vpc is set) | <pre>object({<br/>    cidr             = string<br/>    azs              = list(string)<br/>    private_subnets  = list(string)<br/>    public_subnets   = list(string)<br/>    database_subnets = list(string)<br/>  })</pre> | <pre>{<br/>  "azs": [<br/>    "us-west-2a",<br/>    "us-west-2b",<br/>    "us-west-2c"<br/>  ],<br/>  "cidr": "172.16.0.0/16",<br/>  "database_subnets": [<br/>    "172.16.200.0/24",<br/>    "172.16.201.0/24",<br/>    "172.16.202.0/24"<br/>  ],<br/>  "private_subnets": [<br/>    "172.16.0.0/24",<br/>    "172.16.1.0/24",<br/>    "172.16.2.0/24"<br/>  ],<br/>  "public_subnets": [<br/>    "172.16.100.0/24",<br/>    "172.16.101.0/24",<br/>    "172.16.102.0/24"<br/>  ]<br/>}</pre> | no |
| <a name="input_vpc_endpoints"></a> [vpc\_endpoints](#input\_vpc\_endpoints) | VPC endpoint service short-names to create (empty = none). s3/dynamodb are free Gateway endpoints; others are Interface endpoints. See the variable comment for the recommended set and cost. Internal VPC only. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cert_manager_role_arn"></a> [cert\_manager\_role\_arn](#output\_cert\_manager\_role\_arn) | ARN of the Cert Manager IRSA role |
| <a name="output_cilium_k8s_service_host"></a> [cilium\_k8s\_service\_host](#output\_cilium\_k8s\_service\_host) | Kubernetes API server host (no https:// scheme) for Cilium kubeProxyReplacement=true. Set helm k8sServiceHost to this and k8sServicePort to 443. |
| <a name="output_cluster_addons_enabled_resolved"></a> [cluster\_addons\_enabled\_resolved](#output\_cluster\_addons\_enabled\_resolved) | (introspection) Managed addon enablement after resolving cni and the addons.* overrides |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | Cluster security group that was created by Amazon EKS for the cluster |
| <a name="output_cni_node_group_enabled"></a> [cni\_node\_group\_enabled](#output\_cni\_node\_group\_enabled) | (introspection) Whether the dedicated CNI node group is created (true for kube-ovn unless disabled). |
| <a name="output_cni_node_labels_resolved"></a> [cni\_node\_labels\_resolved](#output\_cni\_node\_labels\_resolved) | (introspection) Labels applied to the dedicated CNI node group ({} when not created). |
| <a name="output_cni_node_taints_resolved"></a> [cni\_node\_taints\_resolved](#output\_cni\_node\_taints\_resolved) | (introspection) Taints applied to the dedicated CNI node group ({} when not created). |
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
| <a name="output_initial_node_labels_resolved"></a> [initial\_node\_labels\_resolved](#output\_initial\_node\_labels\_resolved) | (introspection) Labels applied to the initial managed node group after resolving cni and initial\_node.labels(\_extra) |
| <a name="output_initial_node_taints_resolved"></a> [initial\_node\_taints\_resolved](#output\_initial\_node\_taints\_resolved) | (introspection) Taints applied to the initial managed node group after resolving cni and initial\_node.taints(\_extra) |
| <a name="output_karpenter_node_iam_role_name"></a> [karpenter\_node\_iam\_role\_name](#output\_karpenter\_node\_iam\_role\_name) | The name of the Karpenter node IAM role |
| <a name="output_karpenter_queue_name"></a> [karpenter\_queue\_name](#output\_karpenter\_queue\_name) | The name of the Karpenter SQS queue |
| <a name="output_karpenter_role_arn"></a> [karpenter\_role\_arn](#output\_karpenter\_role\_arn) | ARN of the Karpenter IRSA role |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | The Amazon Resource Name (ARN) of the KMS key |
| <a name="output_load_balancer_controller_role_arn"></a> [load\_balancer\_controller\_role\_arn](#output\_load\_balancer\_controller\_role\_arn) | ARN of the ALB controller IRSA role |
| <a name="output_nat_tailscale_conf_resolved"></a> [nat\_tailscale\_conf\_resolved](#output\_nat\_tailscale\_conf\_resolved) | (introspection) Rendered tailscale fck-nat.conf lines per AZ ({} when tailscale is disabled). Only references the SSM parameter name, never the key value. |
| <a name="output_node_security_group_id"></a> [node\_security\_group\_id](#output\_node\_security\_group\_id) | ID of the node shared security group |
| <a name="output_region"></a> [region](#output\_region) | The AWS region the stack is deployed in. Wire into the cni-bootstrap module's region so its node-registration poll can region-qualify the cluster. |
| <a name="output_s3_csi_driver_role_arn"></a> [s3\_csi\_driver\_role\_arn](#output\_s3\_csi\_driver\_role\_arn) | ARN of the S3 CSI driver IRSA role |
| <a name="output_vpc"></a> [vpc](#output\_vpc) | The vpc object when it's created |
| <a name="output_vpc_endpoint_ids"></a> [vpc\_endpoint\_ids](#output\_vpc\_endpoint\_ids) | Map of created VPC endpoint ids (empty when vpc\_endpoints is empty). |
<!-- END_TF_DOCS -->
