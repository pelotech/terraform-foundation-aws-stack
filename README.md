![pre-commit](https://github.com/pelotech/terraform-foundation-aws-stack/actions/workflows/pre-commit.yaml/badge.svg)

# Foundation - Pelotech's GitOps K8s Cluster
This is the terraform module that helps bootstrap foundation in AWS

This project uses [release-please](https://github.com/googleapis/release-please) for the release flow of contributions

> **Upgrading between major versions?** Breaking changes and migration steps
> live in [UPGRADING.md](UPGRADING.md).

## CNI selection

Pick a CNI with `cni` — it sets the initial node group taints/labels and
the vpc-cni/kube-proxy addon toggles to match. All values remain overridable
(see below).

| `cni`               | vpc-cni | kube-proxy | Initial-group taints/labels                   | Notes                                                       |
| ------------------- | ------- | ---------- | --------------------------------------------- | ----------------------------------------------------------- |
| `cilium` (default)  | off     | off        | `CriticalAddonsOnly` + cilium agent-not-ready | Install Cilium (kube-proxy replacement) via Helm.           |
| `kube-ovn`          | off     | on         | `CriticalAddonsOnly` + nidhogg gates           | Also adds a dedicated CNI node group (see note). Install via Helm/ArgoCD post-bootstrap. |
| `vpc-cni`           | on      | on         | `CriticalAddonsOnly`                           | AWS native. IRSA / prefix delegation via `*_overrides`.     |

> **kube-ovn** provisions an extra dedicated 1-node `cni-<stack>` node group that
> carries the `kube-ovn/role=master` label + the `kube-ovn.io/control-plane` taint
> and requires `cni_node.kubernetes_version`. See
> ["Node upgrades on kube-ovn"](#node-upgrades-on-kube-ovn-version-bumps--security-patches).

For any other CNI, pick the closest profile and override the addon toggles /
taints / labels as needed — anything that wants a clean slate works the same.

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
  cni = "kube-ovn" # vpc-cni off, kube-proxy on; system group gets CriticalAddonsOnly + nidhogg gates

  # kubernetes_version is required for kube-ovn: pins the dedicated CNI node group
  # (kube-ovn/role=master + control-plane taint) so a control-plane bump never
  # auto-rolls the master node.
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
register before installing (needs `aws`+`kubectl` on the apply host). Wire
`wait_for_nodes_count = module.foundation.cni_node_size` too: if it undercounts the group the
install races the nodes, and if it overcounts the poll hangs until `wait_for_nodes_timeout` and
fails the apply.
`cni = "custom"` installs any Helm-packaged CNI via `custom_chart`; layer extra
values with `helm_set` / `helm_values`. See `modules/cni-bootstrap/README.md`.
As a safety net, set `initial_node = { ..., timeouts = { create = "20m" } }` so a failed
bring-up fails fast instead of 60m. This replaces the imperative
`helm upgrade --install` bootstrap step.

> **Migrating an existing cluster** that already installed its CNI via
> `helm install`? Import the release first or the apply fails with
> `cannot re-use a name that is still in use` — see
> ["Adopting an existing release"](modules/cni-bootstrap/README.md#adopting-an-existing-release-migrating-from-imperative-helm-install)
> in the cni-bootstrap README.

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

## Node upgrades on kube-ovn (version bumps & security patches)

kube-ovn pins `ovn-central` to the master nodes present at deploy time (via
`MASTER_NODES_LABEL`), so replacing those nodes with a normal in-place EKS rolling
update breaks it mid-roll and deadlocks. Node replacement must be a **deliberate
recycle** (destroy/recreate).

**How it's structured:** for `cni = "kube-ovn"` the module runs **two** node
groups — the `initial-<stack>` **system group** (coredns + critical addons; carries
`CriticalAddonsOnly` + the nidhogg gating taints; follows `cluster_version`; rolls
in place) and a dedicated 1-node `cni-<stack>` **control-plane group**
(`kube-ovn/role=master` + control-plane taint; version-pinned; recycled). Because
the recycle destroys **only the
1-node CNI group**, coredns/DNS and the system group stay up — no coredns/PDB dance,
and at most one coredns replica is ever disrupted so its PDB is always satisfied.
(`cilium`/`vpc-cni` get just the one initial group.)

> That guarantee holds because coredns **cannot schedule onto the CNI group** — it does not
> tolerate the `kube-ovn.io/control-plane` taint. Since the CNI node is the newest and emptiest in
> the cluster right after a recycle, it is exactly what the scheduler would otherwise pick. If you
> override `addons.overrides["coredns"].configuration_values`, do not add a blanket
> `{ operator = "Exists" }` toleration: that reintroduces the problem, and step 2 below would take
> down DNS alongside `ovn-central`. Check the resolved value with the
> `coredns_tolerations_resolved` output.

**Breaking:** for `cni = "kube-ovn"` you must set **`cni_node.kubernetes_version`**
(pin the CNI group's k8s version). This decouples it from `cluster_version`, so a
control-plane bump does **not** auto-roll the master node.

> **If the system-group roll fails with `PodEvictionFailure`** ("Reached max
> retries while trying to evict pods"), a PodDisruptionBudget blocked eviction —
> diagnose with `kubectl get pdb -A` (look for `ALLOWED DISRUPTIONS: 0`) and
> `kubectl get events -A -w` during the roll. As a last resort,
> `initial_node = { force_update_version = true }` makes EKS delete pods whose
> eviction stays PDB-blocked instead of failing the update.

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

### AMI updates

The AMI is resolved with a `most_recent` lookup against `ami_name_filter`. By
default a newer AMI only produces a new launch template version — the running
instance is not replaced; recycle it manually (terminate the instance and the
ASG relaunches it from the latest launch template version). Set
`pelotech_nat.auto_rollout = true` to opt in to automatic rolling: an apply
that picks up a newer AMI triggers an instance refresh on the NAT auto scaling
group. The old instance is terminated before its replacement attaches the
network interface, so expect a brief per-AZ NAT egress outage during the roll.

### Migrating from the managed NAT gateway (keeping your EIPs)

Switching an existing stack to `pelotech_nat` normally destroys the managed
NAT gateways **and their EIPs**, changing your egress IPs. To keep the same
addresses, move the vpc module's NAT EIPs into this module's `aws_eip.main`.
Counts align one-to-one per AZ (managed NAT runs one gateway + EIP per AZ),
so the move is index-for-index.

Requires Terraform >= 1.3 (`moved` across module packages). In the same
change that sets `pelotech_nat = { enabled = true }`, add one `moved` block
per AZ to your root module:

```hcl
moved {
  from = module.<stack>.module.vpc.aws_eip.nat[0]
  to   = module.<stack>.aws_eip.main[0]
}
moved {
  from = module.<stack>.module.vpc.aws_eip.nat[1]
  to   = module.<stack>.aws_eip.main[1]
}
# ...one per AZ
```

The plan must show the EIPs **moved and updated in place** (tag changes only
— `Name` becomes `nat-<name>-<i>`), NOT destroyed. The NAT gateways are
destroyed and the fck-nat instances re-associate the same allocations at
boot. Once applied, the moved blocks can be deleted.

Alternatively, run `terraform state mv` with the same from/to addresses —
but do it **before** the apply that flips `enabled = true`, or the plan will
destroy and release the addresses.

Notes:

- Adapt `module.<stack>` to how you instantiate the module (drop it entirely
  if this module is your root).
- Confirm index↔AZ alignment first with
  `terraform state show 'module.<stack>.module.vpc.aws_eip.nat[0]'` — both
  resources iterate the AZ list in the same order.
- Expect a brief per-AZ egress outage during cutover. If an instance boots
  before its AZ's NAT gateway is fully deleted, its EIP association fails —
  terminate that instance (the ASG relaunches it) and the association
  re-runs at boot.

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

## Workload identity (Pod Identity / IRSA)

This module creates IAM roles for six cluster workloads. It does **not** install the controllers
themselves — it emits role ARNs and the GitOps layer wires them up.

| Identity key | Namespace | Service account |
| ------------ | --------- | --------------- |
| `load_balancer_controller` | `alb` | `aws-load-balancer-controller` |
| `ebs_csi_driver` | `kube-system` | `ebs-csi-driver` |
| `s3_csi_driver` | `kube-system` | `s3-csi-driver` |
| `external_dns` | `external-dns` | `external-dns-controller` |
| `cert_manager` | `cert-manager` | `cert-manager` |
| `karpenter` | `karpenter` | `karpenter` |

Since v9, each identity gets an **EKS Pod Identity** role and association by default, plus the
`eks-pod-identity-agent` addon. No `eks.amazonaws.com/role-arn` annotation is needed. The IRSA roles
are created alongside them and remain fully supported — Pod Identity cannot serve Fargate, so IRSA
is not going away. See [UPGRADING.md](UPGRADING.md) for the migration.

The agent is installed automatically — there is no manual step. It is enabled whenever at least one
identity uses Pod Identity (including the partial-opt-out case below, where the remaining
identities still need it), and it is installed `before_compute`, ahead of the node groups, so a
node group failure cannot leave associations behind with nothing to serve them.

> **The agent is what actually vends credentials.** `addons = { pod_identity_agent = false }`
> forces it off, which combined with Pod Identity being enabled produces associations that nothing
> serves: the apply succeeds, the associations look correct in the console, and pods silently get
> no credentials. Force it off only if you run the agent yourself. Conversely, force it **on** if
> you disable Pod Identity here but create associations out of band.

### Choosing a mechanism

`irsa` and `pod_identity` toggle independently, and both default to `enabled = true`:

| `irsa` | `pod_identity` | State |
| ------ | -------------- | ----- |
| on | off | All IRSA — pre-v9 behavior, and the rollback target |
| on | on | **Both — the default.** Each identity has a role for each mechanism |
| off | on | All Pod Identity — the v10 default, reachable now with a one-flag rollback |
| off | off | No role from this module — for identities you manage out of band |

Both also resolve **per identity**: the override wins, otherwise the variable's `enabled`. So the
table describes the fallback each identity takes, not a cluster-wide mode.

```hcl
pod_identity = {
  enabled = true                                    # default
  overrides = {
    cert_manager = { enabled = false }              # this identity is left to `irsa`
  }
}

irsa = {
  enabled = false                                   # everything moves to Pod Identity...
  overrides = {
    external_dns = { enabled = true }               # ...except this one
  }
}
```

That second shape is why per-identity `irsa` overrides exist: the agent is a DaemonSet and does not
run on Fargate, so a controller scheduled there has to stay on IRSA. Without overrides, keeping one
controller on IRSA means keeping all six.

Leaving an identity on neither mechanism is allowed, but this module then creates no role for it and
nothing warns you at plan time. Karpenter is a partial exception: its role is created whenever
`create` is true, so turning both mechanisms off only drops the web-identity trust statement and the
association — the role itself stays.

> **Pod Identity wins over an IRSA service account annotation.** If a workload must keep using its
> annotation, you have to disable Pod Identity for that identity — removing the association is the
> only thing that yields precedence back.

#### The cluster OIDC provider

The IAM OIDC provider is created whenever **any** identity still resolves to IRSA, so it disappears
on its own once the last one moves — nulling `eks_oidc_provider_arn` and breaking any out-of-band
role federating against it. Keep it explicitly if you have such roles:

```hcl
irsa = {
  enabled              = false
  create_oidc_provider = true   # keep the provider for out-of-band IRSA roles
}
```

Forcing it `false` while an identity still uses IRSA is rejected at plan — those roles federate
against the provider you would be suppressing. The issuer URL (`eks_oidc_provider`) belongs to the
cluster and is populated either way.

Each identity exposes two outputs: `<identity>_role_arn` for the Pod Identity role and
`<identity>_irsa_role_arn` for the IRSA role. Both are null when that identity is not on the
mechanism. `karpenter_role_arn` is a single output for both — Karpenter reuses one role.

### Scoping Route53 access

`cert_manager` and `external_dns` default to an unscoped Route53 grant. Narrow it with:

```hcl
pod_identity = {
  overrides = {
    cert_manager = { hosted_zone_arns = ["arn:aws:route53:::hostedzone/Z0123456789ABCDEFGHIJ"] }
    external_dns = { hosted_zone_arns = ["arn:aws:route53:::hostedzone/Z0123456789ABCDEFGHIJ"] }
  }
}
```

This applies to the Pod Identity roles only. An identity left on IRSA — the GovCloud case below —
keeps its own unscoped grant, because the IRSA roles are deliberately never modified. An empty list
is rejected: it renders an IAM statement with no `Resource`. Omit the attribute to stay unscoped.

### Cross-account DNS — same partition

When the hosted zones live in another account in the *same* partition, use Pod Identity role
chaining. The local role becomes a stub that assumes the target role, and the target role carries
the Route53 permissions:

```hcl
pod_identity = {
  overrides = {
    external_dns = { target_role_arn = "arn:aws:iam::210987654321:role/dns-writer" }
  }
}
```

The target role's trust policy must allow `sts:AssumeRole` (and `sts:TagSession`, unless you set
`disable_session_tags = true`) from `external_dns_role_arn`.

### Cross-account DNS — GovCloud to commercial

**Pod Identity cannot do this.** Role chaining is `sts:AssumeRole`, and IAM cannot express trust
across partitions. IRSA can, because it is OIDC web-identity federation. Keep the DNS identities
on IRSA:

```hcl
pod_identity = {
  overrides = {
    cert_manager = { enabled = false }
    external_dns = { enabled = false }
  }
}
```

In the **commercial** account, register the GovCloud cluster's issuer and a role that trusts it:

```hcl
# No thumbprint_list: it is optional, and when omitted IAM retrieves the issuer's CA thumbprint
# itself. For EKS-style (S3-hosted JWKS) endpoints AWS validates against its own trusted-CA library
# and ignores any thumbprint you do configure, so supplying one is dead weight.
resource "aws_iam_openid_connect_provider" "gov_cluster" {
  url            = "https://${module.foundation.eks_oidc_provider}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "cert_manager_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gov_cluster.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.foundation.eks_oidc_provider}:sub"
      values   = ["system:serviceaccount:cert-manager:cert-manager"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.foundation.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
```

Then annotate the service account with the **commercial** role ARN. Nothing extra is needed in the
GovCloud account — the gov-side OIDC provider plays no part in this flow.

Two things that will otherwise cost you an afternoon:

- **STS endpoint.** The pod identity webhook injects `AWS_STS_REGIONAL_ENDPOINTS=regional` and
  `AWS_REGION=<gov region>`, so the SDK calls GovCloud STS with a commercial role ARN and fails.
  Set `AWS_STS_REGIONAL_ENDPOINTS=global` (or an explicit commercial region) on the cert-manager
  and external-dns containers.
- **Egress.** These pods must reach commercial STS and Route53. VPC endpoints do not cross
  partitions, so this needs real internet egress — relevant if you run a NAT-less topology via
  `vpc_endpoints`.

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
| <a name="module_cert_manager_irsa_role"></a> [cert\_manager\_irsa\_role](#module\_cert\_manager\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.8.0 |
| <a name="module_cert_manager_pod_identity"></a> [cert\_manager\_pod\_identity](#module\_cert\_manager\_pod\_identity) | terraform-aws-modules/eks-pod-identity/aws | 2.8.2 |
| <a name="module_ebs_csi_driver_irsa_role"></a> [ebs\_csi\_driver\_irsa\_role](#module\_ebs\_csi\_driver\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.8.0 |
| <a name="module_ebs_csi_driver_pod_identity"></a> [ebs\_csi\_driver\_pod\_identity](#module\_ebs\_csi\_driver\_pod\_identity) | terraform-aws-modules/eks-pod-identity/aws | 2.8.2 |
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | 21.24.1 |
| <a name="module_external_dns_irsa_role"></a> [external\_dns\_irsa\_role](#module\_external\_dns\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.8.0 |
| <a name="module_external_dns_pod_identity"></a> [external\_dns\_pod\_identity](#module\_external\_dns\_pod\_identity) | terraform-aws-modules/eks-pod-identity/aws | 2.8.2 |
| <a name="module_fck_nat"></a> [fck\_nat](#module\_fck\_nat) | git::https://github.com/josmo/terraform-aws-fck-nat.git | v1.6.1-pre-josmo |
| <a name="module_karpenter"></a> [karpenter](#module\_karpenter) | terraform-aws-modules/eks/aws//modules/karpenter | 21.24.1 |
| <a name="module_load_balancer_controller_irsa_role"></a> [load\_balancer\_controller\_irsa\_role](#module\_load\_balancer\_controller\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.8.0 |
| <a name="module_load_balancer_controller_pod_identity"></a> [load\_balancer\_controller\_pod\_identity](#module\_load\_balancer\_controller\_pod\_identity) | terraform-aws-modules/eks-pod-identity/aws | 2.8.2 |
| <a name="module_s3_csi"></a> [s3\_csi](#module\_s3\_csi) | terraform-aws-modules/s3-bucket/aws | 5.15.4 |
| <a name="module_s3_csi_driver_pod_identity"></a> [s3\_csi\_driver\_pod\_identity](#module\_s3\_csi\_driver\_pod\_identity) | terraform-aws-modules/eks-pod-identity/aws | 2.8.2 |
| <a name="module_s3_driver_irsa_role"></a> [s3\_driver\_irsa\_role](#module\_s3\_driver\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | 6.8.0 |
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
| [aws_iam_policy_document.pod_identity_target_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.source](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_initial_node"></a> [initial\_node](#input\_initial\_node) | Initial (system) managed node group. instance\_types is required and must all be one architecture (the node AMI type is derived from them). taints/labels: leave null to derive from the cni profile merged with taints\_extra/labels\_extra (caller keys win); set to a map to replace the preset entirely ({} for none). force\_update\_version: evict through PodDisruptionBudgets when a version roll exhausts the per-node eviction window (escape hatch for PodEvictionFailure; pods blocked by a PDB are deleted). Default false. | <pre>object({<br/>    instance_types       = list(string)<br/>    enabled              = optional(bool, true)<br/>    min_size             = optional(number, 2)<br/>    max_size             = optional(number, 6)<br/>    desired_size         = optional(number, 3)<br/>    force_update_version = optional(bool, false)<br/>    taints               = optional(map(object({ key = string, value = string, effect = string })))<br/>    taints_extra         = optional(map(object({ key = string, value = string, effect = string })), {})<br/>    labels               = optional(map(string))<br/>    labels_extra         = optional(map(string), {})<br/>    timeouts = optional(object({<br/>      create = optional(string)<br/>      update = optional(string)<br/>      delete = optional(string)<br/>    }))<br/>  })</pre> | n/a | yes |
| <a name="input_access"></a> [access](#input\_access) | IAM role ARNs granted cluster access. admin\_arns: cluster admins. admin\_ro\_arns: admin read only with secret and configmap access. ro\_arns: read only. KMS: admin\_arns AND admin\_ro\_arns are both granted KMS key *administrator* on the cluster secrets key — that includes kms:PutKeyPolicy and kms:ScheduleKeyDeletion, so admin\_ro\_arns is not read-only with respect to KMS and can self-escalate or schedule the key for deletion. ro\_arns receives no KMS access at all. For genuinely least-privilege access, use extra\_access\_entries instead of admin\_ro\_arns. | <pre>object({<br/>    admin_arns    = optional(list(string), [])<br/>    admin_ro_arns = optional(list(string), [])<br/>    ro_arns       = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| <a name="input_addons"></a> [addons](#input\_addons) | Managed cluster addon toggles and overrides. vpc\_cni/kube\_proxy: leave null (default) to derive from the cni profile (vpc-cni: on for cni=vpc-cni; kube-proxy: off for cilium kube-proxy replacement); set true/false to force. When the vpc-cni addon is off, nodeadm maxPods=110 cloudinit is applied automatically. pod\_identity\_agent: leave null (default) to enable whenever any identity uses Pod Identity; set true/false to force. The agent is what actually vends credentials, so forcing it false while pod\_identity is enabled creates associations with nothing to serve them — the apply still succeeds and the associations look correct, but pods silently get no credentials. Only force false if you run the agent yourself (e.g. a self-managed DaemonSet). Force true if you create pod identity associations out of band while pod\_identity is disabled here. overrides: per-addon overrides keyed by addon name (e.g. "vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent") merged over module defaults — accepts any attributes supported by terraform-aws-modules/eks/aws v21+ `addons` map. | <pre>object({<br/>    vpc_cni            = optional(bool)<br/>    kube_proxy         = optional(bool)<br/>    coredns            = optional(bool, true)<br/>    pod_identity_agent = optional(bool)<br/>    overrides          = optional(any, {})<br/>  })</pre> | `{}` | no |
| <a name="input_cluster_enabled_log_types"></a> [cluster\_enabled\_log\_types](#input\_cluster\_enabled\_log\_types) | List of EKS control plane log types to enable. Valid values: api, audit, authenticator, controllerManager, scheduler. | `list(string)` | `[]` | no |
| <a name="input_cluster_endpoint_public_access"></a> [cluster\_endpoint\_public\_access](#input\_cluster\_endpoint\_public\_access) | Whether the EKS cluster API server endpoint is publicly accessible. Set to false for private-only access (requires VPC connectivity). | `bool` | `true` | no |
| <a name="input_cluster_version"></a> [cluster\_version](#input\_cluster\_version) | Kubernetes version to set for the cluster | `string` | `"1.35"` | no |
| <a name="input_cni"></a> [cni](#input\_cni) | CNI profile driving the initial (system) node group taints/labels and vpc-cni/kube-proxy addon enablement. One of: cilium, kube-ovn, vpc-cni. For kube-ovn the system group carries the nidhogg gating taints, while the kube-ovn/role=master label + control-plane taint go to a dedicated CNI node group (the cni\_node variable). Override individual pieces with initial\_node.taints(\_extra)/labels(\_extra) and the addons toggles. | `string` | `"cilium"` | no |
| <a name="input_cni_node"></a> [cni\_node](#input\_cni\_node) | Dedicated CNI node group (kube-ovn control plane). enabled: null derives from cni (true for kube-ovn, false otherwise); set false, apply, then true again to recycle it (e.g. for a version/AMI upgrade) without touching the initial group. kubernetes\_version: version this group runs — bump to upgrade it; decoupled from cluster\_version so a control-plane bump doesn't auto-roll it (null follows cluster\_version, REQUIRED for cni="kube-ovn"); replace it deliberately via the recycle (toggle enabled + bump cni-bootstrap's bootstrap\_generation). instance\_types: null falls back to initial\_node.instance\_types; must all be one architecture. ami\_release\_version: pin the AMI release (e.g. a same-version security patch); null uses the default AMI for its kubernetes\_version. size: node count (min=max=desired); default 1 = a single kube-ovn ovn-central master. | <pre>object({<br/>    enabled             = optional(bool)<br/>    kubernetes_version  = optional(string)<br/>    instance_types      = optional(list(string))<br/>    ami_release_version = optional(string)<br/>    size                = optional(number, 1)<br/>  })</pre> | `{}` | no |
| <a name="input_create"></a> [create](#input\_create) | Create the EKS cluster and its IAM identities (cluster, node groups, addons, Karpenter, IRSA and Pod Identity roles). NOTE: this does NOT gate the surrounding infrastructure — the VPC, subnets, NAT instances, EIPs, Tailscale SSM parameters, VPC endpoints and the S3 CSI bucket are created regardless, gated by their own variables (existing\_vpc, pelotech\_nat, vpc\_endpoints, s3\_csi). Setting create = false plans successfully but still bills for those. | `bool` | `true` | no |
| <a name="input_create_cluster_kms"></a> [create\_cluster\_kms](#input\_create\_cluster\_kms) | Should secrets be encrypted by kms in the cluster | `bool` | `true` | no |
| <a name="input_create_node_security_group"></a> [create\_node\_security\_group](#input\_create\_node\_security\_group) | Whether to create a dedicated security group for EKS managed node groups. When true, the node\_security\_group\_id output is populated. | `bool` | `false` | no |
| <a name="input_existing_vpc"></a> [existing\_vpc](#input\_existing\_vpc) | Use an existing VPC instead of creating one (null = create the VPC from the vpc variable) | <pre>object({<br/>    vpc_id     = string<br/>    subnet_ids = list(string)<br/>  })</pre> | `null` | no |
| <a name="input_extra_access_entries"></a> [extra\_access\_entries](#input\_extra\_access\_entries) | EKS access entries needed by IAM roles interacting with this cluster | <pre>list(object({<br/>    principal_arn     = string<br/>    kubernetes_groups = optional(list(string))<br/>    policy_associations = optional(map(object({<br/>      policy_arn = string<br/>      access_scope = object({<br/>        type       = string<br/>        namespaces = optional(list(string))<br/>      })<br/>    })), {})<br/><br/>  }))</pre> | `[]` | no |
| <a name="input_irsa"></a> [irsa](#input\_irsa) | IRSA (IAM Roles for Service Accounts) for the workload identities this module creates<br/>(load\_balancer\_controller, ebs\_csi\_driver, s3\_csi\_driver, external\_dns, cert\_manager, karpenter).<br/><br/>Resolves per identity exactly like `pod_identity`: the override wins, otherwise `enabled`. The<br/>two mechanisms are independent, so each identity is on IRSA, on Pod Identity, on both (the<br/>default, which makes a cutover reversible without an IAM change), or on neither.<br/><br/>Mixing matters because the eks-pod-identity-agent is a DaemonSet and does not run on Fargate: a<br/>controller scheduled onto Fargate has to stay on IRSA while the rest of the cluster moves, so<br/>`enabled = false` with an override re-enabling that one identity is the expected shape.<br/><br/>Leaving an identity on neither mechanism is allowed — use it when you manage that role out of<br/>band — but this module then creates no role for it, and nothing warns you at plan time.<br/><br/>enabled              — v10.0.0 flips this default to false, making IRSA opt-in. The roles and<br/>                       the *\_irsa\_role\_arn outputs are permanent; only the default changes.<br/>create\_oidc\_provider — null (default) creates the cluster's IAM OIDC provider whenever any<br/>                       identity resolves to IRSA. Set true to keep it after the last identity<br/>                       has moved, for out-of-band roles that federate against it. The issuer URL<br/>                       (eks\_oidc\_provider) belongs to the cluster and survives either way.<br/><br/>Karpenter has one role trusting both mechanisms rather than a role per mechanism, so it behaves<br/>differently at the edges — see README, "Choosing a mechanism". | <pre>object({<br/>    enabled              = optional(bool, true)<br/>    create_oidc_provider = optional(bool)<br/>    overrides = optional(map(object({<br/>      enabled = optional(bool)<br/>    })), {})<br/>  })</pre> | `{}` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the stack | `string` | `"foundation-stack"` | no |
| <a name="input_node_iam_additional_policies"></a> [node\_iam\_additional\_policies](#input\_node\_iam\_additional\_policies) | Map of IAM policy name to ARN to attach to the managed node group IAM role. | `map(string)` | `{}` | no |
| <a name="input_pelotech_nat"></a> [pelotech\_nat](#input\_pelotech\_nat) | Pelotech NAT instances replacing the managed NAT gateway — a hardened fck-nat-based image (FIPS, L2 compliance, optional Tailscale) from AWS Marketplace. IMPORTANT: the default AMI is the Pelotech NAT image from AWS Marketplace and requires an active Marketplace subscription in the target account — without one the instance launch fails at apply time with OptInRequired. Subscribe first, or point ami\_owner\_id/ami\_name\_filter at your own image. create\_eip creates the NAT EIP even when enabled=false — nice for getting ips created for allow lists. auto\_rollout (default false): when enabled, a newer AMI matching ami\_name\_filter found at apply time triggers a rolling instance refresh on the NAT ASG (brief per-AZ NAT outage while the instance is replaced); leave false to recycle instances manually. tailscale: provide auth via tailscale.auth\_key\_ssm (name of an existing SSM parameter) or pelotech\_nat\_tailscale\_auth\_key (plain key; the module stores it in a SecureString SSM parameter it creates). The instances always read the key from SSM. SecureString params under the default aws/ssm KMS key work as-is; customer-managed KMS keys on an existing parameter require a key-policy grant outside this module. | <pre>object({<br/>    enabled         = optional(bool, false)<br/>    instance_type   = optional(string, "t4g.micro")<br/>    ami_owner_id    = optional(string, "aws-marketplace")<br/>    ami_name_filter = optional(string, "pelotech-nat-al2023-hvm-*")<br/>    create_eip      = optional(bool, false)<br/>    auto_rollout    = optional(bool, false)<br/>    tailscale = optional(object({<br/>      enabled            = optional(bool, false)<br/>      auth_key_ssm       = optional(string, "")<br/>      advertise_routes   = optional(string, "")<br/>      exit_node          = optional(bool, false)<br/>      hostname           = optional(string, "")<br/>      snat_subnet_routes = optional(bool, true)<br/>      extra_args         = optional(string, "")<br/>    }), {})<br/>  })</pre> | `{}` | no |
| <a name="input_pelotech_nat_tailscale_auth_key"></a> [pelotech\_nat\_tailscale\_auth\_key](#input\_pelotech\_nat\_tailscale\_auth\_key) | Plain Tailscale auth key for NAT instances. Stored by the module in a SecureString SSM parameter (never written to user-data; the value does land in terraform state - prefer pelotech\_nat.tailscale.auth\_key\_ssm with a pre-existing parameter). | `string` | `""` | no |
| <a name="input_permissions_boundary"></a> [permissions\_boundary](#input\_permissions\_boundary) | IAM permissions boundary policy name applied to all IAM roles. When set, constructs full ARN from the current account and partition. | `string` | `""` | no |
| <a name="input_pod_identity"></a> [pod\_identity](#input\_pod\_identity) | EKS Pod Identity for the workload identities this module creates (load\_balancer\_controller,<br/>ebs\_csi\_driver, s3\_csi\_driver, external\_dns, cert\_manager, karpenter).<br/><br/>When enabled, each identity gets its own Pod Identity role plus an association, and the<br/>`eks-pod-identity-agent` addon is installed. The IRSA roles are left untouched and keep their<br/>own ARNs, so disabling an identity is a no-op on existing state.<br/><br/>NOTE: Pod Identity takes precedence over an `eks.amazonaws.com/role-arn` service account<br/>annotation. Disable an identity here to keep IRSA serving it.<br/><br/>overrides (keyed by identity name):<br/>  enabled              — false leaves the identity to `irsa`, which may itself be off for it<br/>                         (required in GovCloud for cert\_manager/external\_dns when the hosted<br/>                         zones live in a commercial account, since IAM cannot assume a role<br/>                         across partitions).<br/>  target\_role\_arn      — cross-account role chaining. The target role holds the permissions,<br/>                         so the predefined policy is replaced by an sts:AssumeRole grant.<br/>                         Same-partition only; not supported for karpenter.<br/>  disable\_session\_tags — passed through to the association. Not supported for karpenter.<br/>  hosted\_zone\_arns     — Route53 scoping for cert\_manager/external\_dns only. Null (default)<br/>                         keeps the historic unscoped grant. Applies to the Pod Identity role<br/>                         only: an identity left on IRSA keeps its own unscoped grant, because<br/>                         the IRSA roles are deliberately never modified. | <pre>object({<br/>    enabled = optional(bool, true)<br/>    overrides = optional(map(object({<br/>      enabled              = optional(bool)<br/>      target_role_arn      = optional(string)<br/>      disable_session_tags = optional(bool)<br/>      hosted_zone_arns     = optional(list(string))<br/>    })), {})<br/>  })</pre> | `{}` | no |
| <a name="input_pre_bootstrap_user_data"></a> [pre\_bootstrap\_user\_data](#input\_pre\_bootstrap\_user\_data) | Custom user data script to run before node bootstrap. Useful for installing CA certificates or custom packages. | `string` | `null` | no |
| <a name="input_s3_csi"></a> [s3\_csi](#input\_s3\_csi) | S3 CSI driver bucket access. create\_bucket: create a new bucket for use with the driver. bucket\_name: override the generated bucket name (default "<tags.Owner>-<name>-csi-bucket"); required if tags has no Owner key. bucket\_arns: existing buckets the driver should have access to. When create\_bucket is false and bucket\_arns is empty, no S3 policy is attached to the driver roles at all. | <pre>object({<br/>    create_bucket = optional(bool, true)<br/>    bucket_name   = optional(string)<br/>    bucket_arns   = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | tags to be added to the stack, should at least have Owner and Environment | `map(string)` | <pre>{<br/>  "Environment": "prod",<br/>  "Owner": "pelotech"<br/>}</pre> | no |
| <a name="input_vpc"></a> [vpc](#input\_vpc) | Variables for defining the vpc for the stack (ignored when existing\_vpc is set) | <pre>object({<br/>    cidr             = string<br/>    azs              = list(string)<br/>    private_subnets  = list(string)<br/>    public_subnets   = list(string)<br/>    database_subnets = list(string)<br/>  })</pre> | <pre>{<br/>  "azs": [<br/>    "us-west-2a",<br/>    "us-west-2b",<br/>    "us-west-2c"<br/>  ],<br/>  "cidr": "172.16.0.0/16",<br/>  "database_subnets": [<br/>    "172.16.200.0/24",<br/>    "172.16.201.0/24",<br/>    "172.16.202.0/24"<br/>  ],<br/>  "private_subnets": [<br/>    "172.16.0.0/24",<br/>    "172.16.1.0/24",<br/>    "172.16.2.0/24"<br/>  ],<br/>  "public_subnets": [<br/>    "172.16.100.0/24",<br/>    "172.16.101.0/24",<br/>    "172.16.102.0/24"<br/>  ]<br/>}</pre> | no |
| <a name="input_vpc_endpoints"></a> [vpc\_endpoints](#input\_vpc\_endpoints) | VPC endpoint service short-names to create (empty = none). Interface endpoints let private nodes<br/>reach ECR/STS/SSM/EC2 and be SSM-debuggable without NAT egress; kubelet->API already works<br/>privately via the cluster's endpoint\_private\_access ENIs. Internal (module-created) VPC only.<br/><br/>COST: s3 and dynamodb are free Gateway endpoints. Every other name is an Interface endpoint at<br/>~$7/mo per AZ (about $22/mo per service across 3 AZs) plus data processing.<br/><br/>Recommended set for private/NAT-resilient clusters:<br/>["s3", "ssm", "ssmmessages", "ec2messages", "ec2", "ecr.api", "ecr.dkr", "sts",<br/> "elasticloadbalancing", "autoscaling"] | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cert_manager_irsa_role_arn"></a> [cert\_manager\_irsa\_role\_arn](#output\_cert\_manager\_irsa\_role\_arn) | ARN of the Cert Manager IRSA role. Null when cert\_manager is not on IRSA. |
| <a name="output_cert_manager_role_arn"></a> [cert\_manager\_role\_arn](#output\_cert\_manager\_role\_arn) | ARN of the Cert Manager Pod Identity role |
| <a name="output_cilium_k8s_service_host"></a> [cilium\_k8s\_service\_host](#output\_cilium\_k8s\_service\_host) | Kubernetes API server host (no https:// scheme) for Cilium kubeProxyReplacement=true. Set helm k8sServiceHost to this and k8sServicePort to 443. |
| <a name="output_cluster_addons_enabled_resolved"></a> [cluster\_addons\_enabled\_resolved](#output\_cluster\_addons\_enabled\_resolved) | (introspection) Managed addon enablement after resolving cni and the addons.* overrides |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | Cluster security group that was created by Amazon EKS for the cluster |
| <a name="output_cni_node_group_enabled"></a> [cni\_node\_group\_enabled](#output\_cni\_node\_group\_enabled) | (introspection) Whether the dedicated CNI node group is created (true for kube-ovn unless disabled). |
| <a name="output_cni_node_labels_resolved"></a> [cni\_node\_labels\_resolved](#output\_cni\_node\_labels\_resolved) | (introspection) Labels the cni profile defines for the dedicated CNI node group. Derived from the profile alone, so this stays populated even when the group is not created (e.g. cni\_node.enabled = false) — use cni\_node\_group\_enabled to test for the group's existence. |
| <a name="output_cni_node_size"></a> [cni\_node\_size](#output\_cni\_node\_size) | Size of the dedicated CNI node group. Wire this into the cni-bootstrap module's wait\_for\_nodes\_count — if the two disagree the bootstrap poll hangs until wait\_for\_nodes\_timeout and fails the apply. 0 when no CNI node group is created. |
| <a name="output_cni_node_taints_resolved"></a> [cni\_node\_taints\_resolved](#output\_cni\_node\_taints\_resolved) | (introspection) Taints the cni profile defines for the dedicated CNI node group. Derived from the profile alone, so this stays populated even when the group is not created (e.g. cni\_node.enabled = false) — use cni\_node\_group\_enabled to test for the group's existence. |
| <a name="output_coredns_tolerations_resolved"></a> [coredns\_tolerations\_resolved](#output\_coredns\_tolerations\_resolved) | (introspection) Tolerations added to the coredns addon beyond its own defaults, resolved from the cni profile. Empty means the addon's stock tolerations apply (which already cover CriticalAddonsOnly). |
| <a name="output_database_subnet_group"></a> [database\_subnet\_group](#output\_database\_subnet\_group) | Name of the database subnet group created by this module (null when existing\_vpc is set) |
| <a name="output_ebs_csi_driver_irsa_role_arn"></a> [ebs\_csi\_driver\_irsa\_role\_arn](#output\_ebs\_csi\_driver\_irsa\_role\_arn) | ARN of the EBS CSI driver IRSA role. Null when ebs\_csi\_driver is not on IRSA. |
| <a name="output_ebs_csi_driver_role_arn"></a> [ebs\_csi\_driver\_role\_arn](#output\_ebs\_csi\_driver\_role\_arn) | ARN of the EBS CSI driver Pod Identity role |
| <a name="output_eks_cluster_certificate_authority_data"></a> [eks\_cluster\_certificate\_authority\_data](#output\_eks\_cluster\_certificate\_authority\_data) | Base64 encoded certificate data for the cluster |
| <a name="output_eks_cluster_endpoint"></a> [eks\_cluster\_endpoint](#output\_eks\_cluster\_endpoint) | The endpoint for the EKS cluster API server |
| <a name="output_eks_cluster_iam_role_name"></a> [eks\_cluster\_iam\_role\_name](#output\_eks\_cluster\_iam\_role\_name) | The name of the EKS cluster IAM role |
| <a name="output_eks_cluster_name"></a> [eks\_cluster\_name](#output\_eks\_cluster\_name) | The name of the EKS cluster |
| <a name="output_eks_cluster_service_cidr"></a> [eks\_cluster\_service\_cidr](#output\_eks\_cluster\_service\_cidr) | The cluster's Kubernetes service CIDR (AWS-assigned or configured). Wire into the cni-bootstrap module's service\_cidr for kube-ovn (ipv4.SVC\_CIDR). |
| <a name="output_eks_managed_node_groups"></a> [eks\_managed\_node\_groups](#output\_eks\_managed\_node\_groups) | Map of attribute maps for all EKS managed node groups created |
| <a name="output_eks_managed_node_groups_autoscaling_group_names"></a> [eks\_managed\_node\_groups\_autoscaling\_group\_names](#output\_eks\_managed\_node\_groups\_autoscaling\_group\_names) | List of the autoscaling group names created by EKS managed node groups |
| <a name="output_eks_oidc_provider"></a> [eks\_oidc\_provider](#output\_eks\_oidc\_provider) | The OpenID Connect identity provider (issuer URL without leading `https://`). A property of the cluster itself, so this is populated whether or not the OIDC provider exists. |
| <a name="output_eks_oidc_provider_arn"></a> [eks\_oidc\_provider\_arn](#output\_eks\_oidc\_provider\_arn) | EKS OIDC provider ARN to be able to add IRSA roles to the cluster out of band. Null when no identity uses IRSA and irsa.create\_oidc\_provider is not forced true — the provider is not created. |
| <a name="output_external_dns_irsa_role_arn"></a> [external\_dns\_irsa\_role\_arn](#output\_external\_dns\_irsa\_role\_arn) | ARN of the External DNS IRSA role. Null when external\_dns is not on IRSA. |
| <a name="output_external_dns_role_arn"></a> [external\_dns\_role\_arn](#output\_external\_dns\_role\_arn) | ARN of the External DNS Pod Identity role |
| <a name="output_initial_node_labels_resolved"></a> [initial\_node\_labels\_resolved](#output\_initial\_node\_labels\_resolved) | (introspection) Labels applied to the initial managed node group after resolving cni and initial\_node.labels(\_extra) |
| <a name="output_initial_node_taints_resolved"></a> [initial\_node\_taints\_resolved](#output\_initial\_node\_taints\_resolved) | (introspection) Taints applied to the initial managed node group after resolving cni and initial\_node.taints(\_extra) |
| <a name="output_irsa_enabled_resolved"></a> [irsa\_enabled\_resolved](#output\_irsa\_enabled\_resolved) | (introspection) Per-identity IRSA enablement after resolving create, irsa.enabled and irsa.overrides |
| <a name="output_irsa_oidc_provider_enabled_resolved"></a> [irsa\_oidc\_provider\_enabled\_resolved](#output\_irsa\_oidc\_provider\_enabled\_resolved) | (introspection) Whether the cluster's IAM OIDC provider is created, after resolving create, irsa.create\_oidc\_provider and per-identity IRSA usage |
| <a name="output_karpenter_node_iam_role_name"></a> [karpenter\_node\_iam\_role\_name](#output\_karpenter\_node\_iam\_role\_name) | The name of the Karpenter node IAM role |
| <a name="output_karpenter_queue_name"></a> [karpenter\_queue\_name](#output\_karpenter\_queue\_name) | The name of the Karpenter SQS queue |
| <a name="output_karpenter_role_arn"></a> [karpenter\_role\_arn](#output\_karpenter\_role\_arn) | ARN of the Karpenter controller role. One role serves both mechanisms, so this is correct whether Karpenter uses Pod Identity or IRSA. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | The Amazon Resource Name (ARN) of the KMS key |
| <a name="output_load_balancer_controller_irsa_role_arn"></a> [load\_balancer\_controller\_irsa\_role\_arn](#output\_load\_balancer\_controller\_irsa\_role\_arn) | ARN of the ALB controller IRSA role. Null when load\_balancer\_controller is not on IRSA. |
| <a name="output_load_balancer_controller_role_arn"></a> [load\_balancer\_controller\_role\_arn](#output\_load\_balancer\_controller\_role\_arn) | ARN of the ALB controller Pod Identity role |
| <a name="output_nat_tailscale_conf_resolved"></a> [nat\_tailscale\_conf\_resolved](#output\_nat\_tailscale\_conf\_resolved) | (introspection) Rendered tailscale fck-nat.conf lines per AZ ({} when tailscale is disabled). Only references the SSM parameter name, never the key value. |
| <a name="output_node_security_group_id"></a> [node\_security\_group\_id](#output\_node\_security\_group\_id) | ID of the node shared security group |
| <a name="output_pod_identity_associations_resolved"></a> [pod\_identity\_associations\_resolved](#output\_pod\_identity\_associations\_resolved) | (introspection) Namespace/service-account pairs each enabled identity is associated with, including any cross-account target\_role\_arn |
| <a name="output_pod_identity_enabled_resolved"></a> [pod\_identity\_enabled\_resolved](#output\_pod\_identity\_enabled\_resolved) | (introspection) Per-identity Pod Identity enablement after resolving create, pod\_identity.enabled and pod\_identity.overrides |
| <a name="output_pod_identity_hosted_zone_arns_resolved"></a> [pod\_identity\_hosted\_zone\_arns\_resolved](#output\_pod\_identity\_hosted\_zone\_arns\_resolved) | (introspection) Route53 hosted zone ARNs scoped onto the cert-manager and external-dns Pod Identity roles |
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | IDs of the private subnets created by this module (empty when existing\_vpc is set) |
| <a name="output_public_subnet_ids"></a> [public\_subnet\_ids](#output\_public\_subnet\_ids) | IDs of the public subnets created by this module (empty when existing\_vpc is set) |
| <a name="output_region"></a> [region](#output\_region) | The AWS region the stack is deployed in. Wire into the cni-bootstrap module's region so its node-registration poll can region-qualify the cluster. |
| <a name="output_s3_csi_driver_irsa_role_arn"></a> [s3\_csi\_driver\_irsa\_role\_arn](#output\_s3\_csi\_driver\_irsa\_role\_arn) | ARN of the S3 CSI driver IRSA role. Null when s3\_csi\_driver is not on IRSA. |
| <a name="output_s3_csi_driver_role_arn"></a> [s3\_csi\_driver\_role\_arn](#output\_s3\_csi\_driver\_role\_arn) | ARN of the S3 CSI driver Pod Identity role |
| <a name="output_s3_csi_policy_attached_resolved"></a> [s3\_csi\_policy\_attached\_resolved](#output\_s3\_csi\_policy\_attached\_resolved) | (introspection) Whether the Mountpoint S3 policy is attached to the S3 CSI roles. False when no bucket is created and no bucket\_arns are supplied, which avoids the upstream fallback that would otherwise grant s3:ListBucket on every bucket in the account. |
| <a name="output_vpc_azs"></a> [vpc\_azs](#output\_vpc\_azs) | Availability zones requested for the module-created VPC. NOTE: this echoes vpc.azs and is populated even when existing\_vpc is set. |
| <a name="output_vpc_cidr_block"></a> [vpc\_cidr\_block](#output\_vpc\_cidr\_block) | CIDR block of the VPC created by this module (null when existing\_vpc is set) |
| <a name="output_vpc_endpoints"></a> [vpc\_endpoints](#output\_vpc\_endpoints) | Map of created VPC endpoints, keyed by service short-name. Values are the full aws\_vpc\_endpoint resource objects, not bare IDs — use e.g. vpc\_endpoints["s3"].id. Empty when vpc\_endpoints is empty or existing\_vpc is set. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | ID of the VPC created by this module (null when existing\_vpc is set) |
<!-- END_TF_DOCS -->
