# Access entries are keyed by principal ARN, so adding, removing or reordering an ARN only touches
# that entry (before v10 they were keyed by list position). Mocked AWS provider.

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
  access = {
    admin_arns    = ["arn:aws:iam::123456789012:role/ci", "arn:aws:iam::123456789012:role/admin"]
    admin_ro_arns = ["arn:aws:iam::123456789012:role/auditor"]
  }
}

run "arn_keys" {
  command = plan

  variables {
    extra_access_entries = [{
      principal_arn = "arn:aws:iam::123456789012:role/deployer"
    }]
  }

  assert {
    condition = toset(keys(local.managed_access_entries)) == toset([
      "arn:aws:iam::123456789012:role/ci",
      "arn:aws:iam::123456789012:role/admin",
      "arn:aws:iam::123456789012:role/auditor",
    ])
    error_message = "managed entries must be keyed by principal ARN"
  }

  assert {
    condition     = toset(keys(local.extra_access_entries)) == toset(["arn:aws:iam::123456789012:role/deployer"])
    error_message = "extra entries must be keyed by principal ARN"
  }
}

run "arn_keys_survive_mid_list_removal" {
  command = plan

  variables {
    access = {
      admin_arns    = ["arn:aws:iam::123456789012:role/admin"]
      admin_ro_arns = ["arn:aws:iam::123456789012:role/auditor"]
    }
  }

  assert {
    condition     = local.managed_access_entries["arn:aws:iam::123456789012:role/admin"].principal_arn == "arn:aws:iam::123456789012:role/admin"
    error_message = "removing an earlier ARN must not change the key of a later one"
  }
}

run "duplicate_arn_across_groups_rejected" {
  command = plan

  variables {
    access = {
      admin_arns = ["arn:aws:iam::123456789012:role/admin"]
      ro_arns    = ["arn:aws:iam::123456789012:role/admin"]
    }
  }

  expect_failures = [var.access]
}

run "duplicate_arn_in_extra_rejected" {
  command = plan

  variables {
    extra_access_entries = [{
      principal_arn = "arn:aws:iam::123456789012:role/ci"
    }]
  }

  expect_failures = [var.access]
}
