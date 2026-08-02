# Upgrade guide

Breaking changes and migration steps between major versions, newest first.
General usage documentation lives in the [README](README.md).

## Upgrading to v9.0.0 (breaking changes)

EKS Pod Identity replaces IRSA as the default credential mechanism for the identities this
module creates. The IRSA roles are **not** modified or removed in v9 — new Pod Identity roles are
created alongside them, and the migration is reversible with one flag. v10.0.0 will delete the
IRSA roles.

### ⚠️ Read this first if you run GovCloud with hosted zones in a commercial account

**Pod Identity takes precedence over an `eks.amazonaws.com/role-arn` service account annotation.**
If cert-manager and external-dns in your GovCloud cluster assume a role in a *commercial* account
via IRSA, the default v9 behavior will shadow that annotation and DNS will start failing with
`AccessDenied` against GovCloud Route53 at the next pod restart.

Set the opt-out **in the same commit as the version bump**, not afterwards:

```hcl
module "foundation" {
  # ...
  pod_identity = {
    overrides = {
      cert_manager = { enabled = false }
      external_dns = { enabled = false }
    }
  }
}
```

This is not a temporary workaround. IAM cannot assume a role across partitions, so Pod Identity's
cross-account path (`target_role_arn`) can never reach a commercial account from `aws-us-gov`.
IRSA can, because it is OIDC web-identity federation: the commercial account registers an
`aws_iam_openid_connect_provider` against your GovCloud cluster's issuer URL. The only thing the
commercial side needs from here is `eks_oidc_provider` (the issuer URL without `https://`) — no
thumbprint, see below. Nothing in the GovCloud account is required beyond leaving these two
identities on IRSA.

Every *other* identity (ALB controller, EBS CSI, S3 CSI, Karpenter) uses Pod Identity normally in
GovCloud — the opt-out is per-identity, not cluster-wide.

Once you are fully migrated you can also set `irsa = { enabled = false }`: the gov-side IRSA roles
for these two are dead weight, because the role they actually assume lives in the commercial
account. The cross-partition flow is unaffected — it federates against the gov cluster's *issuer*
and a provider object in the *commercial* account, so the gov-side provider plays no part in it,
and `eks_oidc_provider` keeps working because the issuer belongs to the cluster.

### Role ARNs change

The five migrated identities get **new roles with new ARNs**. Nothing inside this module
references them, but audit anything outside it that names the old ARN in a *resource* policy:
KMS key policies, S3 bucket policies, or a cross-account trust policy in a DNS account.

| Identity | IRSA role (still exists in v9) | New Pod Identity role |
| -------- | ------------------------------ | --------------------- |
| ALB controller | `${name}-alb-role` | `${name}-alb-pod-identity-role` |
| EBS CSI | `${name}-ebs-csi-driver-role` | `${name}-ebs-csi-driver-pod-identity-role` |
| S3 CSI | `${name}-s3-csi-driver-role` | `${name}-s3-csi-driver-pod-identity-role` |
| external-dns | `${name}-external-dns-role` | `${name}-external-dns-pod-identity-role` |
| cert-manager | `${name}-cert-manager-role` | `${name}-cert-manager-pod-identity-role` |
| Karpenter | `${name}-karpenter-role` | *(unchanged — reuses the same role)* |

Karpenter is the one identity without a parallel role: its role already trusted
`pods.eks.amazonaws.com`, so it keeps its ARN and only gains an association.
`karpenter_role_arn` covers both mechanisms and does not change.

### Output renames

The `*_role_arn` names now point at the **Pod Identity** roles, and the legacy IRSA roles moved to
`*_irsa_role_arn`. Doing this in v9 means v10 only *deletes* the IRSA outputs — you take one
naming break instead of two.

| v8 output | v9 output | Points at |
| --------- | --------- | --------- |
| `load_balancer_controller_role_arn` | `load_balancer_controller_irsa_role_arn` | IRSA role (deprecated) |
| `ebs_csi_driver_role_arn` | `ebs_csi_driver_irsa_role_arn` | IRSA role (deprecated) |
| `s3_csi_driver_role_arn` | `s3_csi_driver_irsa_role_arn` | IRSA role (deprecated) |
| `external_dns_role_arn` | `external_dns_irsa_role_arn` | IRSA role (deprecated) |
| `cert_manager_role_arn` | `cert_manager_irsa_role_arn` | IRSA role (deprecated) |
| — | `load_balancer_controller_role_arn` | **Pod Identity role (new meaning)** |
| — | `ebs_csi_driver_role_arn` | **Pod Identity role (new meaning)** |
| — | `s3_csi_driver_role_arn` | **Pod Identity role (new meaning)** |
| — | `external_dns_role_arn` | **Pod Identity role (new meaning)** |
| — | `cert_manager_role_arn` | **Pod Identity role (new meaning)** |
| `karpenter_role_arn` | `karpenter_role_arn` | unchanged — one role, both mechanisms |

**The five reused names silently change meaning.** If you consume `cert_manager_role_arn` to write
a service account annotation, it now resolves to the Pod Identity role — and returns `null` for any
identity you disabled. GovCloud consumers keeping cert-manager and external-dns on IRSA must switch
those references to `*_irsa_role_arn`.

### `eks_cluster_tls_certificate_sha1_fingerprint` removed

Its only purpose was supplying `thumbprint_list` to an `aws_iam_openid_connect_provider`, and that
argument is optional. When it is omitted, IAM retrieves the issuer's top intermediate CA thumbprint
itself. For EKS-style endpoints (Amazon S3-hosted JWKS) AWS goes further and validates against its
own trusted-CA library, *ignoring* any thumbprint you configure — so the value was being computed,
exported, and then discarded.

Drop the argument:

```hcl
resource "aws_iam_openid_connect_provider" "cluster" {
  url            = "https://${module.foundation.eks_oidc_provider}"
  client_id_list = ["sts.amazonaws.com"]
}
```

If you have a genuine need for one — a non-EKS IdP behind a private CA, say — derive it yourself:

```hcl
data "tls_certificate" "cluster" {
  url = "https://${module.foundation.eks_oidc_provider}"
}
# thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
```

Removing `thumbprint_list` from an **existing** provider is cosmetic: the AWS provider does not
send an update for an emptied list, so the previously-registered thumbprint simply stays. That is
harmless, since it is not used for verification.

### Choosing a mechanism: `irsa` and `pod_identity`

The two toggles are independent, which gives three usable states:

| `irsa.enabled` | `pod_identity.enabled` | State |
| -------------- | ---------------------- | ----- |
| `true` | `false` | All IRSA — v8 behavior, and the rollback target |
| `true` | `true` | **Both — the v9 default.** Every identity has a role for each mechanism |
| `false` | `true` | All Pod Identity — the v10 end state, reachable now |

Both `false` is rejected at plan; it would create no workload identity roles at all. Use
`create = false` if you want nothing.

Running the end state early is the point of the `irsa` toggle: you can validate
`irsa = { enabled = false }` under v9 and roll back with one flag, instead of discovering problems
at the v10 major where the roles are gone for good.

Note what disabling IRSA also removes: the cluster's **IAM OIDC provider**. That nulls
`eks_oidc_provider_arn` and breaks any out-of-band role that federates against it. The issuer URL
(`eks_oidc_provider`) is a property of the cluster and survives — see the GovCloud section above.

### What happens on first apply against an existing cluster

The plan is **create-only**. No existing IAM role is modified or destroyed, Karpenter included:

- **+1 addon** — `eks-pod-identity-agent` (a DaemonSet; enabled automatically whenever any identity
  uses Pod Identity, forceable with `addons.pod_identity_agent`)
- **+5 IAM roles and policies** — the Pod Identity roles above
- **+6 pod identity associations** — five from the new roles, one from the Karpenter submodule
- **0 changes** to the five IRSA roles, and none to Karpenter's

Pods pick up the new credentials at their next restart, not at apply time.

Karpenter has a single role rather than a parallel one, but that role trusts **both** mechanisms
simultaneously: the upstream submodule always emits a `pods.eks.amazonaws.com` trust statement, and
the web-identity statement is now keyed off `irsa.enabled` rather than off Pod Identity. So with
the default (both enabled) it holds the web-identity trust *and* an association at once, and gets
the same dual-mode window as everything else. Its trust policy is only rewritten when you actually
turn IRSA off.

### Rollback

```hcl
pod_identity = { enabled = false }
```

Apply, then restart the affected pods. This is complete and needs no IAM change — the IRSA roles
were never touched, and Karpenter keeps its web-identity trust throughout.

### After migrating

Remove the `eks.amazonaws.com/role-arn` annotations from your Helm values / GitOps layer once
Pod Identity is confirmed working. v10.0.0 deletes the IRSA roles and the `*_irsa_role_arn`
outputs; the `*_role_arn` names are already final and will not change again.

### `create = false` now plans

`create = false` could never plan before v9. `load_balancer_controller_irsa_role` and
`ebs_csi_driver_irsa_role` had no `count`, so they built a trust policy from a null
`module.eks.oidc_provider_arn` and failed with `provider_arn is null`. Two smaller null-safety
holes sat behind it: `data.aws_iam_policy_document.source` (Karpenter's web-identity trust)
interpolated a null `module.eks.oidc_provider`, and the `cilium_k8s_service_host` output called
`replace()` on a null cluster endpoint.

All four are fixed. **No action is required for the default `create = true`.** Adding `count`
re-keys those two roles from `module.x` to `module.x[0]`, and `moved.tf` carries the state across —
no role is replaced and no ARN changes. `terraform plan` shows the moves as a no-op.

**`create` does not gate the whole module.** It covers the cluster and its IAM identities — the
EKS cluster, node groups, addons, Karpenter and every IRSA/Pod Identity role. It does **not** gate
the surrounding infrastructure, which is still created and still billed:

| Still created with `create = false` | Gated instead by |
| ----------------------------------- | ---------------- |
| VPC, subnets, route tables, internet/NAT gateways | `existing_vpc` |
| NAT instances, EIPs, Tailscale SSM parameters | `pelotech_nat` |
| VPC endpoints | `vpc_endpoints` |
| S3 CSI bucket | `s3_csi.create_bucket` |

To no-op the entire module, set those alongside `create = false`. The variable description now
says this explicitly.

Three outputs can now return `null` where they previously always had a value, but only when
`create = false` (a configuration that could not plan at all before, so nothing can regress):
`load_balancer_controller_irsa_role_arn`, `ebs_csi_driver_irsa_role_arn`, `cilium_k8s_service_host`.

### Other breaking changes in v9.0.0

**`var.dns` removed** — Route53 scoping moved into `pod_identity.overrides`, so per-identity
settings all live in one place:

```hcl
# v9 (was: dns = { external_dns_hosted_zone_arns = [...] })
pod_identity = {
  overrides = {
    external_dns = { hosted_zone_arns = ["arn:aws:route53:::hostedzone/Z1"] }
  }
}
```

Only valid for `cert_manager` and `external_dns`, and an empty list is now rejected — it rendered
an IAM statement with no `Resource`. Omit the attribute to keep the unscoped grant. Scoping applies
to the Pod Identity role only; an identity left on IRSA keeps its own unscoped grant, because the
IRSA roles are deliberately never modified.

**`output "vpc"` replaced.** It re-exported all 119 outputs of `terraform-aws-modules/vpc` as this
module's public API, which made any upstream major a silent breaking change here. Replaced with
named outputs:

| Was | Now |
| --- | --- |
| `vpc.vpc_id` | `vpc_id` |
| `vpc.vpc_cidr_block` | `vpc_cidr_block` |
| `vpc.azs` | `vpc_azs` |
| `vpc.private_subnets` | `private_subnet_ids` |
| `vpc.public_subnets` | `public_subnet_ids` |
| `vpc.database_subnet_group` | `database_subnet_group` |

Need something else off the VPC module? Open an issue rather than reaching through — that is the
coupling this change removes.

**`vpc_endpoint_ids` renamed to `vpc_endpoints`.** The value was never IDs; it is a map of full
`aws_vpc_endpoint` objects keyed by service short-name. Use `vpc_endpoints["s3"].id`.

**Node group sizing is now a hard error.** `initial_node` min/desired/max agreement was a `check`
block, which only emits a *warning* — an invalid sizing reached the AWS API and failed there.
It is now a variable `validation`, so it fails at plan.

**New input validations** reject configurations that previously failed deep in the plan with an
opaque error, or silently misbehaved:

- `pelotech_nat.enabled` (or `create_eip`) combined with `existing_vpc` — the module can only place
  NAT instances in subnets and route tables it created. Previously an index-out-of-range.
- `vpc.azs` longer than `vpc.public_subnets` or `vpc.private_subnets` — same index crash.
- `tags` without an `Owner` key and no `s3_csi.bucket_name` — `Owner` was an undeclared required
  key feeding an S3 bucket name. `s3_csi.bucket_name` is a new escape hatch, and is validated
  against S3's lowercase/3-63-character naming rules.
- `cni_node.size` of 0, and an empty `cni_node.instance_types`.

**S3 CSI policy is skipped when there are no buckets.** With `s3_csi = { create_bucket = false }`
and no `bucket_arns`, the upstream policy fell back to granting `s3:ListBucket` on
`arn:aws:s3:::*` — every bucket in the account. The policy is now simply not attached.

### Corrected documentation (no behavior change)

- **`access` and KMS.** The description claimed both `*_ro` groups get "KMS readonly access". They
  do not. `admin_arns` **and** `admin_ro_arns` are both granted KMS key *administrator* on the
  cluster secrets key — which includes `kms:PutKeyPolicy` and `kms:ScheduleKeyDeletion` — and
  `ro_arns` gets no KMS access at all. Behavior is unchanged in v9; only the description is now
  accurate. **If you rely on `admin_ro_arns` being read-only, it is not** — use
  `extra_access_entries` for least-privilege access.
- **Access entry keys are positional.** `access.*_arns` entries are keyed by list index, so
  removing or reordering an ARN mid-list destroys and recreates every access entry after it.
  Append new ARNs at the end.
- **`cni_node_taints_resolved` / `cni_node_labels_resolved`** are derived from the CNI profile
  alone and stay populated even when the node group is not created. Use `cni_node_group_enabled`.

### CoreDNS tolerations are now scoped per CNI profile

CoreDNS was configured with a blanket `tolerations = [{ operator = "Exists" }]`, which tolerates
**every** taint. That was added in v8 to get CoreDNS past a single kube-ovn nidhogg gate, and has
since silently grown to cover two taints that did not exist when it was written. It is now derived
from the CNI profile:

| `cni` | Tolerations added beyond the addon's defaults |
| ----- | --------------------------------------------- |
| `cilium` | none |
| `vpc-cni` | none |
| `kube-ovn` | `nidhogg.uswitch.com/kube-system.kube-ovn-pinger`, `nidhogg.uswitch.com/kube-system.kube-multus-ds` |

Why each is safe:

- **`CriticalAddonsOnly` never needed one.** The EKS CoreDNS addon ships tolerating it already, so
  the override was redundant on every profile. (It also *replaced* the addon's defaults rather than
  appending, which silently dropped the stock `node-role.kubernetes.io/control-plane` toleration.)
- **cilium's `node.cilium.io/agent-not-ready:NoExecute` self-clears.** `cilium-operator` removes it
  once the agent is ready and EKS does not re-apply it, so the taint gates CoreDNS only until the
  CNI is usable — which is the point of it.
- **kube-ovn keeps its nidhogg gates**, which is the deadlock the blanket was originally added for.

**The fix: CoreDNS no longer tolerates `kube-ovn.io/control-plane`.** The dedicated CNI node group
is destroyed and recreated on every kube-ovn recycle, and the ["Node upgrades on
kube-ovn"](README.md#node-upgrades-on-kube-ovn-version-bumps--security-patches) runbook promises DNS
survives that *because* CoreDNS is not on that node. The blanket toleration made it schedulable
there — and right after a recycle that node is the emptiest in the cluster, exactly what the
scheduler prefers. A replica landing there turned step 2 of the runbook into a simultaneous
`ovn-central` and DNS outage, and could trip the CoreDNS PDB into `PodEvictionFailure`.

**Action required only if** you add custom taints to the system group via
`initial_node.taints`/`taints_extra` and were relying on the blanket toleration to keep CoreDNS
schedulable past them. Add a matching toleration:

```hcl
addons = {
  overrides = {
    "coredns" = {
      configuration_values = jsonencode({
        tolerations = [{ key = "your-custom-taint", operator = "Exists" }]
      })
    }
  }
}
```

Note this override *replaces* the derived list, so on kube-ovn restate the two nidhogg entries
alongside yours. The resolved value is exposed as the `coredns_tolerations_resolved` output.

### The Pod Identity agent is now installed before the node groups

`eks-pod-identity-agent` sets `before_compute = true`. Previously it landed in the upstream
`aws_eks_addon.this` resource, which depends on every node group — so the agent was created **last**,
while the Pod Identity associations were created **first**. A node group failure (bad AMI, capacity,
`initial_node.timeouts` expiring) left every association in place with no agent to serve them, and
nothing in the output pointing at the cause.

No action required. On a successful apply the ordering was never visible; this only changes what a
*failed* apply leaves behind. It is safe with zero nodes — a DaemonSet addon has no desired replicas
and reports ACTIVE, exactly as `vpc-cni` already does on this path.

### New: `cni_node_size` output

Wire it into the `cni-bootstrap` module's `wait_for_nodes_count`. If the two disagree the
bootstrap poll hangs until `wait_for_nodes_timeout` and fails the apply; previously the number had
to be copied by hand.

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
