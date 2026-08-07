# Input-validation guards for configurations that previously failed deep inside a plan with an
# opaque error (index out of range, "map does not have an element with the key Owner") or, worse,
# succeeded and produced something wrong. Uses a mocked AWS provider — no credentials or state.

mock_provider "aws" {
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
}

################################################################################
# initial_node sizing
#
# Was a `check` block, which only emits a warning — bad sizing reached the AWS API and
# terraform test could not catch it. Now a validation, so it is a hard error and assertable.
################################################################################

run "desired_below_min_rejected" {
  command = plan

  variables {
    initial_node = { instance_types = ["m5.large"], min_size = 5, desired_size = 2, max_size = 9 }
  }

  expect_failures = [var.initial_node]
}

run "desired_above_max_rejected" {
  command = plan

  variables {
    initial_node = { instance_types = ["m5.large"], min_size = 1, desired_size = 9, max_size = 4 }
  }

  expect_failures = [var.initial_node]
}

run "valid_sizing_accepted" {
  command = plan

  variables {
    initial_node = { instance_types = ["m5.large"], min_size = 1, desired_size = 2, max_size = 4 }
  }

  assert {
    condition     = output.eks_cluster_name == "foundation-stack"
    error_message = "a valid initial_node sizing must plan cleanly"
  }
}

################################################################################
# NAT instances vs existing_vpc
#
# module.vpc.azs echoes var.vpc.azs even when create_vpc is false, while public_subnets and
# private_route_table_ids collapse to empty — so the NAT count was non-zero and indexing them
# blew up with "index out of range".
################################################################################

run "nat_with_existing_vpc_rejected" {
  command = plan

  variables {
    existing_vpc = { vpc_id = "vpc-123", subnet_ids = ["subnet-1", "subnet-2"] }
    pelotech_nat = { enabled = true }
  }

  expect_failures = [var.pelotech_nat]
}

run "nat_eip_with_existing_vpc_rejected" {
  command = plan

  variables {
    existing_vpc = { vpc_id = "vpc-123", subnet_ids = ["subnet-1", "subnet-2"] }
    pelotech_nat = { create_eip = true }
  }

  expect_failures = [var.pelotech_nat]
}

run "existing_vpc_without_nat_accepted" {
  command = plan

  variables {
    existing_vpc = { vpc_id = "vpc-123", subnet_ids = ["subnet-1", "subnet-2"] }
  }

  assert {
    condition     = output.eks_cluster_name == "foundation-stack"
    error_message = "existing_vpc without NAT must plan cleanly"
  }
}

################################################################################
# VPC subnet/AZ agreement — per-AZ resources index the subnet lists by AZ position
################################################################################

run "fewer_public_subnets_than_azs_rejected" {
  command = plan

  variables {
    vpc = {
      cidr             = "172.16.0.0/16"
      azs              = ["us-west-2a", "us-west-2b", "us-west-2c"]
      private_subnets  = ["172.16.0.0/24", "172.16.1.0/24", "172.16.2.0/24"]
      public_subnets   = ["172.16.100.0/24"]
      database_subnets = []
    }
  }

  expect_failures = [var.vpc]
}

run "fewer_private_subnets_than_azs_rejected" {
  command = plan

  variables {
    vpc = {
      cidr             = "172.16.0.0/16"
      azs              = ["us-west-2a", "us-west-2b", "us-west-2c"]
      private_subnets  = ["172.16.0.0/24"]
      public_subnets   = ["172.16.100.0/24", "172.16.101.0/24", "172.16.102.0/24"]
      database_subnets = []
    }
  }

  expect_failures = [var.vpc]
}

################################################################################
# S3 CSI bucket naming — tags.Owner was an undeclared required key feeding a bucket name
################################################################################

run "tags_without_owner_rejected" {
  command = plan

  variables {
    tags = { Environment = "dev" }
  }

  expect_failures = [var.s3_csi]
}

run "tags_without_owner_accepted_with_explicit_bucket_name" {
  command = plan

  variables {
    tags   = { Environment = "dev" }
    s3_csi = { bucket_name = "acme-dev-csi-bucket" }
  }

  assert {
    condition     = output.eks_cluster_name == "foundation-stack"
    error_message = "an explicit s3_csi.bucket_name must remove the tags.Owner requirement"
  }
}

run "invalid_bucket_name_rejected" {
  command = plan

  variables {
    s3_csi = { bucket_name = "Not_A_Valid_Bucket" }
  }

  expect_failures = [var.s3_csi]
}

################################################################################
# cni_node
################################################################################

run "zero_cni_node_size_rejected" {
  command = plan

  variables {
    cni      = "kube-ovn"
    cni_node = { kubernetes_version = "1.35", size = 0 }
  }

  expect_failures = [var.cni_node]
}

run "empty_cni_node_instance_types_rejected" {
  command = plan

  variables {
    cni      = "kube-ovn"
    cni_node = { kubernetes_version = "1.35", instance_types = [] }
  }

  expect_failures = [var.cni_node]
}

# cni_node_size feeds the cni-bootstrap module's wait_for_nodes_count; a mismatch hangs the
# bootstrap poll until it times out and fails the apply.
run "cni_node_size_exported" {
  command = plan

  variables {
    cni      = "kube-ovn"
    cni_node = { kubernetes_version = "1.35", size = 3 }
  }

  assert {
    condition     = output.cni_node_size == 3
    error_message = "cni_node_size must expose the dedicated CNI node group size"
  }
}

run "cni_node_size_zero_when_no_group" {
  command = plan

  assert {
    condition     = output.cni_node_size == 0
    error_message = "cni_node_size must be 0 when no CNI node group is created"
  }
}
