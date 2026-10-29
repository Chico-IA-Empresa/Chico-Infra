mock_provider "aws" {
  override_during = plan
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:sa-east-1:123456789012:key/11111111-1111-1111-1111-111111111111" }
  }
}
mock_provider "aws" {
  alias           = "billing"
  override_during = plan
}
variables {
  account_id                   = "123456789012"
  owner                        = "synthetic-only"
  cost_center                  = "synthetic-only"
  audit_bucket_name            = "synthetic-audit-only"
  audit_access_log_bucket_name = "synthetic-audit-access-only"
  access_log_retention_days    = 30
  audit_kms_key_arn            = "arn:aws:kms:sa-east-1:123456789012:key/synthetic-test"
  oidc_provider_arn            = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  state_bucket_arn             = "arn:aws:s3:::synthetic-state-only"
  alert_emails                 = ["synthetic-only@example.invalid"]
  budget_limits                = { account = 200, shared = 10, dev = 10, uat = 60, prod = 120 }
  oidc_bindings = {
    ci-build-dev  = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = false, state_access = false }
    ci-deploy-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = false, state_access = false }
  }
  credit_approval = { account_id = "123456789012", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
}

run "proof_ci_disabled_by_default" {
  command = plan
  variables { provision_enabled = true }
  assert {
    condition     = length(aws_iam_policy.dev_proof_ci) == 0 && length(aws_iam_role_policy_attachment.dev_proof_ci) == 0 && output.dev_proof_ci_review == null
    error_message = "Existing Shared inputs must not gain proof policies by default."
  }
}

run "proof_ci_cannot_bypass_provision_gate" {
  command = plan
  variables { dev_proof_ci = { instance_id = "i-0123456789abcdef0", review_reference = "synthetic-only" } }
  assert {
    condition     = length(aws_iam_policy.dev_proof_ci) == 0 && length(aws_iam_role_policy_attachment.dev_proof_ci) == 0
    error_message = "Opt-in cannot bypass provision_enabled."
  }
}

run "proof_ci_exact_build_and_status_grants" {
  command = plan
  variables {
    provision_enabled = true
    dev_proof_ci      = { instance_id = "i-0123456789abcdef0", review_reference = "synthetic-only" }
  }
  assert {
    condition = length(aws_iam_policy.dev_proof_ci) == 2 && length(aws_iam_role_policy_attachment.dev_proof_ci) == 2 && (
      aws_iam_role_policy_attachment.dev_proof_ci["build"].role == "ci-build-dev" && aws_iam_role_policy_attachment.dev_proof_ci["status"].role == "ci-deploy-dev"
    ) && length(aws_iam_policy.dev_infra) == 0 && length(aws_iam_policy.dev_boundary) == 0
    error_message = "Proof policies attach only to their two distinct roles and do not change infra/runtime grants."
  }
  assert {
    condition = jsondecode(aws_iam_policy.dev_proof_ci["build"].policy) == jsondecode(jsonencode({ Version = "2012-10-17", Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:DescribeImageScanFindings"], Resource = [for name in ["api", "workers", "frontend"] : "arn:aws:ecr:sa-east-1:123456789012:repository/chico-${name}"] },
      { Effect = "Allow", Action = ["ecr:GetRegistryScanningConfiguration"], Resource = "*" }
    ] }))
    error_message = "Build must equal the reviewed ECR-only candidate, including the two unavoidable global metadata/token actions."
  }
  assert {
    condition = jsondecode(aws_iam_policy.dev_proof_ci["status"].policy) == jsondecode(jsonencode({ Version = "2012-10-17", Statement = [
      { Effect = "Allow", Action = ["ssm:SendCommand"], Resource = ["arn:aws:ssm:sa-east-1:123456789012:document/chico-dev-fixture-status"] },
      { Effect = "Allow", Action = ["ssm:SendCommand"], Resource = ["arn:aws:ec2:sa-east-1:123456789012:instance/i-0123456789abcdef0"], Condition = { StringEquals = { "ssm:resourceTag/env" = "dev", "ssm:resourceTag/project" = "chicoai" } } },
      { Effect = "Allow", Action = ["ssm:GetCommandInvocation"], Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = "sa-east-1" } } }
    ] })) && !output.dev_proof_ci_review.state_access && !output.dev_proof_ci_review.arbitrary_shell
    error_message = "Status must equal the fixed document/tagged exact instance candidate; no state, shell, secrets or extra actions."
  }
}

run "proof_ci_rejects_foreign_repository" {
  command = plan
  variables {
    provision_enabled = true
    dev_proof_ci      = { instance_id = "i-0123456789abcdef0", review_reference = "synthetic-only" }
    oidc_bindings = {
      ci-build-dev  = { scope = "dev", repository = "foreign/repo", environment = "infra-apply-dev", writable_state = false, state_access = false }
      ci-deploy-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = false, state_access = false }
    }
  }
  expect_failures = [aws_iam_policy.dev_proof_ci["build"]]
}

run "proof_ci_rejects_wrong_environment_or_scope" {
  command = plan
  variables {
    provision_enabled = true
    dev_proof_ci      = { instance_id = "i-0123456789abcdef0", review_reference = "synthetic-only" }
    oidc_bindings = {
      ci-build-dev  = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-plan-dev", writable_state = false, state_access = false }
      ci-deploy-dev = { scope = "prod", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = false, state_access = false }
    }
  }
  expect_failures = [aws_iam_policy.dev_proof_ci["build"], aws_iam_policy.dev_proof_ci["status"]]
}

run "proof_ci_rejects_foreign_custom_subject" {
  command = plan
  variables {
    provision_enabled      = true
    dev_proof_ci           = { instance_id = "i-0123456789abcdef0", review_reference = "synthetic-only" }
    verified_oidc_subjects = { ci-build-dev = "repo:foreign/repo:environment:infra-apply-dev" }
  }
  expect_failures = [aws_iam_policy.dev_proof_ci["build"]]
}

run "proof_ci_rejects_missing_binding" {
  command = plan
  variables {
    provision_enabled = true
    dev_proof_ci      = { instance_id = "i-0123456789abcdef0", review_reference = "synthetic-only" }
    oidc_bindings = {
      ci-build-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = false, state_access = false }
    }
  }
  expect_failures = [aws_iam_policy.dev_proof_ci["status"]]
}

run "proof_ci_rejects_wildcard_instance" {
  command = plan
  variables {
    provision_enabled = true
    dev_proof_ci      = { instance_id = "*", review_reference = "synthetic-only" }
  }
  expect_failures = [var.dev_proof_ci]
}

run "proof_ci_rejects_empty_review_reference" {
  command = plan
  variables {
    provision_enabled = true
    dev_proof_ci      = { instance_id = "i-0123456789abcdef0", review_reference = " " }
  }
  expect_failures = [var.dev_proof_ci]
}
