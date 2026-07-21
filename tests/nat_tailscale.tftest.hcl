# Validates the tailscale integration for the pelotech NAT instances: the
# rendered /etc/fck-nat.conf lines, the always-SSM auth key handling (existing
# parameter vs module-created SecureString), and the per-instance IAM policy.
# Uses a mocked AWS provider so no credentials, state, or live cluster are needed.
#
# NOTE: run-level `variables` replace whole values (no object deep-merge), so
# every run that sets pelotech_nat must restate enabled = true.

mock_provider "aws" {
  # aws_iam_policy_document renders JSON; the auto-generated mock string is not
  # valid JSON and trips downstream IAM role validation. Force a valid object.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
  # The generated partition mock is a random string, which makes IAM ARNs like
  # arn:${partition}:iam::aws:policy/... invalid. Pin it to a real partition.
  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }
  # Callers/session context are fed into aws_iam_session_context, which validates
  # its arn input; the random mock is not a valid ARN.
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
  pelotech_nat = { enabled = true }
}

run "existing_ssm_param" {
  command = plan

  variables {
    pelotech_nat = {
      enabled = true
      tailscale = {
        enabled          = true
        auth_key_ssm     = "/tailscale/key"
        advertise_routes = "172.16.0.0/16"
        exit_node        = true
      }
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.nat_tailscale_ssm) == 3
    error_message = "tailscale must attach one SSM read policy per NAT instance (one per AZ)"
  }
  assert {
    condition     = length(aws_ssm_parameter.nat_tailscale_auth_key) == 0
    error_message = "an existing auth_key_ssm must not create a new SSM parameter"
  }
  assert {
    condition     = contains(output.nat_tailscale_conf_resolved["us-west-2a"], "tailscale_auth_key_ssm=\"/tailscale/key\"")
    error_message = "conf must reference the provided SSM parameter name"
  }
  assert {
    condition     = contains(output.nat_tailscale_conf_resolved["us-west-2a"], "tailscale_hostname=\"foundation-stack-us-west-2a\"") && contains(output.nat_tailscale_conf_resolved["us-west-2b"], "tailscale_hostname=\"foundation-stack-us-west-2b\"")
    error_message = "tailscale hostname must be the stack name suffixed per AZ"
  }
  assert {
    condition     = contains(output.nat_tailscale_conf_resolved["us-west-2a"], "tailscale_advertise_routes=\"172.16.0.0/16\"") && contains(output.nat_tailscale_conf_resolved["us-west-2a"], "tailscale_exit_node=\"true\"")
    error_message = "advertise_routes and exit_node must be rendered when set"
  }
  assert {
    condition     = length([for l in output.nat_tailscale_conf_resolved["us-west-2a"] : l if strcontains(l, "tailscale_snat_subnet_routes")]) == 0
    error_message = "snat_subnet_routes must not be rendered when left at its default (true)"
  }
}

run "plain_key_creates_ssm_param" {
  command = plan

  variables {
    pelotech_nat = {
      enabled   = true
      tailscale = { enabled = true }
    }
    pelotech_nat_tailscale_auth_key = "tskey-auth-test123"
  }

  assert {
    condition     = length(aws_ssm_parameter.nat_tailscale_auth_key) == 1 && aws_ssm_parameter.nat_tailscale_auth_key[0].type == "SecureString" && aws_ssm_parameter.nat_tailscale_auth_key[0].name == "/foundation-stack/nat/tailscale-auth-key"
    error_message = "a plain auth key must be stored in a module-created SecureString SSM parameter"
  }
  assert {
    condition     = length(aws_iam_role_policy.nat_tailscale_ssm) == 3
    error_message = "tailscale must attach one SSM read policy per NAT instance (one per AZ)"
  }
  assert {
    condition     = contains(output.nat_tailscale_conf_resolved["us-west-2a"], "tailscale_auth_key_ssm=\"/foundation-stack/nat/tailscale-auth-key\"")
    error_message = "conf must reference the module-created SSM parameter name"
  }
  assert {
    condition     = length([for l in output.nat_tailscale_conf_resolved["us-west-2a"] : l if strcontains(l, "tskey-auth-test123")]) == 0
    error_message = "the plain auth key value must never appear in the rendered conf/user-data"
  }
}

run "hostname_override" {
  command = plan

  variables {
    pelotech_nat = {
      enabled = true
      tailscale = {
        enabled      = true
        auth_key_ssm = "/tailscale/key"
        hostname     = "edge"
      }
    }
  }

  assert {
    condition     = contains(output.nat_tailscale_conf_resolved["us-west-2c"], "tailscale_hostname=\"edge-us-west-2c\"")
    error_message = "a hostname override must still be suffixed per AZ"
  }
}

run "enabled_requires_a_key" {
  command = plan

  variables {
    pelotech_nat = {
      enabled   = true
      tailscale = { enabled = true }
    }
  }

  expect_failures = [var.pelotech_nat]
}

run "enabled_rejects_both_keys" {
  command = plan

  variables {
    pelotech_nat = {
      enabled = true
      tailscale = {
        enabled      = true
        auth_key_ssm = "/tailscale/key"
      }
    }
    pelotech_nat_tailscale_auth_key = "tskey-auth-test123"
  }

  expect_failures = [var.pelotech_nat]
}

run "disabled_emits_nothing" {
  command = plan

  variables {
    pelotech_nat = {
      enabled = false
      tailscale = {
        enabled      = true
        auth_key_ssm = "/tailscale/key"
      }
    }
  }

  assert {
    condition     = length(output.nat_tailscale_conf_resolved) == 0
    error_message = "tailscale conf must be empty when the pelotech NAT itself is disabled"
  }
  assert {
    condition     = length(aws_iam_role_policy.nat_tailscale_ssm) == 0 && length(aws_ssm_parameter.nat_tailscale_auth_key) == 0
    error_message = "no IAM policy or SSM parameter may be created when the pelotech NAT is disabled"
  }
}
