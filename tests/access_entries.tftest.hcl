# access_entries: caller-keyed map; `access` is shorthand for one cluster-wide policy.
# Mocked AWS provider.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:role/test"
      id         = "123456789012"
      user_id    = "AIDATEST"
    }
  }
  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:role/test"
    }
  }
}

variables {
  initial_node = { instance_types = ["m5.large"] }
  access_entries = {
    ci      = { principal_arn = "arn:aws:iam::123456789012:role/ci", access = "admin" }
    auditor = { principal_arn = "arn:aws:iam::123456789012:role/auditor", access = "admin_ro" }
    viewer  = { principal_arn = "arn:aws:iam::123456789012:role/viewer", access = "ro" }
    custom = {
      principal_arn     = "arn:aws:iam::123456789012:role/custom"
      kubernetes_groups = ["team:view"]
      policy_associations = {
        ns_edit = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = { type = "namespace", namespaces = ["team"] }
        }
      }
    }
  }
}

run "caller_keys_and_access_shorthand" {
  command = plan

  assert {
    condition     = toset(keys(local.access_entries)) == toset(["ci", "auditor", "viewer", "custom"])
    error_message = "entries must be keyed by the caller's names"
  }

  assert {
    condition     = local.access_entries["ci"].policy_associations["cluster_admin"].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    error_message = "access = admin must add the cluster admin policy"
  }

  assert {
    condition     = local.access_entries["auditor"].policy_associations["admin_view_only"].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
    error_message = "access = admin_ro must add the admin view policy"
  }

  assert {
    condition     = local.access_entries["viewer"].policy_associations["view_only"].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
    error_message = "access = ro must add the view policy"
  }

  assert {
    condition     = jsonencode(keys(local.access_entries["custom"].policy_associations)) == jsonencode(["ns_edit"]) && jsonencode(local.access_entries["custom"].kubernetes_groups) == jsonencode(["team:view"])
    error_message = "an entry without access must pass its groups and policies through unchanged"
  }
}

run "kms_administrators_are_admin_and_admin_ro" {
  command = plan

  assert {
    condition     = toset(local.kms_key_administrators) == toset(["arn:aws:iam::123456789012:role/ci", "arn:aws:iam::123456789012:role/auditor"])
    error_message = "only admin and admin_ro entries are KMS key administrators"
  }
}

run "invalid_access_rejected" {
  command = plan

  variables {
    access_entries = { x = { principal_arn = "arn:aws:iam::123456789012:role/x", access = "owner" } }
  }

  expect_failures = [var.access_entries]
}

run "duplicate_principal_rejected" {
  command = plan

  variables {
    access_entries = {
      a = { principal_arn = "arn:aws:iam::123456789012:role/x", access = "admin" }
      b = { principal_arn = "arn:aws:iam::123456789012:role/x", access = "ro" }
    }
  }

  expect_failures = [var.access_entries]
}
