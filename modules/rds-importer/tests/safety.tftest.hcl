mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = { architecture = "x86_64", state = "available", name = "al2023-ami-synthetic", product_codes = [] }
  }
  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-test" }
  }
}
variables {
  account_id            = "123456789012"
  ami_id                = "ami-test"
  vpc_id                = "vpc-test"
  subnet_id             = "subnet-test"
  rds_security_group_id = "sg-rds-test"
  key_arn               = "arn:aws:kms:sa-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
  master_secret_arns    = ["arn:aws:secretsmanager:sa-east-1:123456789012:secret:rds!test-db-abcdef"]
  toolchain_digest      = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  not_before_utc        = timeadd(timestamp(), "-1h")
  expires_at_utc        = timeadd(timestamp(), "1h")
  dump = {
    bucket     = "chico-prod-recovery-123456789012-sa-east-1"
    key        = "imports/synthetic-test/database.dump"
    version_id = "synthetic-version"
    sha256     = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
}
run "restricted_importer" {
  command = plan
  assert {
    condition     = jsondecode(aws_iam_policy.boundary.policy) == jsondecode(aws_iam_role_policy.this.policy)
    error_message = "Boundary must cap every allowed importer permission."
  }
  assert {
    condition     = local.policy.Statement[3].Action == ["s3:GetObjectVersion"] && local.policy.Statement[3].Condition.StringEquals["s3:VersionId"] == var.dump.version_id
    error_message = "Do not grant latest, listing, upload or delete access to dump/source."
  }
  assert {
    condition     = local.policy.Statement[0].Effect == "Deny" && local.policy.Statement[1].Effect == "Deny" && length(local.policy.Statement[4].Resource) == 1
    error_message = "Keep explicit lease denials and exact master secret scope."
  }
  assert {
    condition     = length(aws_security_group.this.ingress) == 0 && aws_vpc_security_group_egress_rule.postgres.referenced_security_group_id == var.rds_security_group_id && aws_vpc_security_group_egress_rule.postgres.to_port == 5432
    error_message = "Importer must have no inbound ports and SQL egress only to the RDS SG."
  }
  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required" && aws_instance.this.root_block_device[0].encrypted && !aws_instance.this.root_block_device[0].delete_on_termination && aws_instance.this.disable_api_termination
    error_message = "Use IMDSv2 and preserve encrypted workspace."
  }
}
run "reject_legacy_source_as_dump" {
  command = plan
  variables {
    dump = { bucket = "chico-backup", key = "imports/synthetic-test/database.dump", version_id = "synthetic-version", sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  }
  expect_failures = [var.dump]
}
run "reject_unversioned_dump" {
  command = plan
  variables {
    dump = { bucket = "chico-prod-recovery-123456789012-sa-east-1", key = "imports/synthetic-test/database.dump", version_id = "null", sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  }
  expect_failures = [var.dump]
}
run "reject_application_secret" {
  command = plan
  variables { master_secret_arns = ["arn:aws:secretsmanager:sa-east-1:123456789012:secret:application-abcdef"] }
  expect_failures = [var.master_secret_arns]
}
run "reject_expired_lease" {
  command = plan
  variables {
    not_before_utc = "2020-01-01T00:00:00Z"
    expires_at_utc = "2020-01-02T00:00:00Z"
  }
  expect_failures = [aws_instance.this]
}
run "independent_proof_has_separate_sql_route" {
  command = plan
  variables {
    proof_access_enabled    = true
    proof_security_group_id = "sg-proof-test"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.proof[0].security_group_id == "sg-proof-test" && aws_vpc_security_group_egress_rule.proof[0].referenced_security_group_id == "sg-proof-test"
    error_message = "Proof access must not reuse the application-facing target SG."
  }
}
