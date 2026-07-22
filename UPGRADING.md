# Upgrade guide

Breaking changes and migration steps between major versions, newest first.
General usage documentation lives in the [README](README.md).

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
["Pelotech NAT instances"](README.md#pelotech-nat-instances-aws-marketplace) — or pin the
old public image back via `pelotech_nat = { ami_owner_id = "568608671756", ami_name_filter = "fck-nat-al2023-hvm-*" }`.

### CNI profile selector

This release introduces a single **`cni`** selector that drives the initial
node group's taints/labels *and* the vpc-cni/kube-proxy addon enablement from one
CNI profile. The supported profiles are `cilium`, `kube-ovn`, and `vpc-cni`, and
the **default is now `cilium`** (previously the defaults silently assumed kube-ovn
+ multus/nidhogg). The taints/labels below apply to the **initial (system) node
group**; for `kube-ovn` the master label + control-plane taint go to a dedicated
CNI node group (see the note under the table).

| CNI profile | Initial-group taints                                                  | Initial-group labels | vpc-cni | kube-proxy |
| ----------- | --------------------------------------------------------------------- | -------------------- | ------- | ---------- |
| `cilium`    | `CriticalAddonsOnly`, `node.cilium.io/agent-not-ready:NO_EXECUTE`     | none                 | off     | off        |
| `kube-ovn`  | `CriticalAddonsOnly` + nidhogg gates (kube-ovn-pinger, kube-multus-ds) | none                 | off     | on         |
| `vpc-cni`   | `CriticalAddonsOnly`                                                  | none                 | on      | on         |

> **kube-ovn** additionally provisions a dedicated 1-node `cni-<stack>` node group
> that carries the `kube-ovn/role=master` label + the `kube-ovn.io/control-plane`
> taint and hosts `ovn-central` — kept separate so upgrades recycle it without
> touching the system group. See
> ["Node upgrades on kube-ovn"](README.md#node-upgrades-on-kube-ovn-version-bumps--security-patches)
> in the README.

### What happens on first apply against an existing cluster

- **Set `cni` to match your current CNI.** Consumers previously on the
  defaults were effectively running kube-ovn — set `cni = "kube-ovn"` (and
  `cni_node.kubernetes_version`, now required). Note this **provisions the new
  dedicated `cni-<stack>` node group** and moves the master label off the
  initial group (the nidhogg gating taints stay on it), so expect the new group
  plus an initial-group roll — it does **not** preserve the old single-group
  layout unchanged.
- **Leaving the default (`cilium`) changes node group taints/labels**, which
  forces the managed node group to roll/replace nodes. Only take the default
  if you intend to run Cilium.
- `addons.vpc_cni` / `addons.kube_proxy` defaults
  changed from `false`/`true` to **`null`** — they now *derive* from
  `cni`. Set them to an explicit `true`/`false` to override the profile.

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

## Upgrading to v7.0.0 (breaking changes)

This release puts the three core EKS addons under Terraform management via
the EKS managed-addons API, with per-addon enable toggles. **vpc-cni is now
opt-in** (`stack_enable_vpc_cni_addon` defaults to `false`); kube-proxy and
coredns default to `true`. `stack_use_vpc_cni_max_pods` is removed.

### What happens on first apply against an existing cluster (v7)

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
(see [CNI selection](README.md#cni-selection) in the README), install your CNI
out-of-band (Helm, ArgoCD) using the existing outputs (`eks_cluster_endpoint`,
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
> `stack_cluster_addons_overrides` (see
> [Power-user overrides](README.md#power-user-overrides) in the README).
